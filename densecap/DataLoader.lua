require 'hdf5'
local utils = require 'densecap.utils'
local box_utils = require 'densecap.box_utils'

local DataLoader = torch.class('DataLoader')

function DataLoader:__init(opt)
  self.h5_read_all = utils.getopt(opt, 'h5_read_all', false) -- read everything in memory once?
  self.use_split_indicator = utils.getopt(opt, 'use_split_indicator', true)
  self.debug_max_train_images = utils.getopt(opt, 'debug_max_train_images', -1)
  self.proposal_regions_h5 = utils.getopt(opt, 'proposal_regions_h5', '')
  assert(opt.h5_file ~= nil, 'DataLoader input error: must provide h5_file')
  assert(opt.json_file ~= nil, 'DataLoader input error: must provide json_file')

  -- load the json file which contains additional information about the dataset
  print('DataLoader loading json file: ', opt.json_file)
  self.info = utils.read_json(opt.json_file)
  self.vocab_size = utils.count_keys(self.info.idx_to_token)

  -- open the hdf5 file
  print('DataLoader loading h5 file: ', opt.h5_file)
  self.h5_file = hdf5.open(opt.h5_file, 'r')
  local keys = {}
  table.insert(keys, 'box_to_img')
  table.insert(keys, 'boxes')
  table.insert(keys, 'image_heights')
  table.insert(keys, 'image_widths')
  table.insert(keys, 'img_to_first_box')
  table.insert(keys, 'img_to_last_box')
  table.insert(keys, 'labels')
  table.insert(keys, 'lengths')
  table.insert(keys, 'original_heights')
  table.insert(keys, 'original_widths')
  if self.use_split_indicator then
    table.insert(keys, 'split')
  end
  if self.h5_read_all then
    table.insert(keys, 'images') -- TODO remote and do partial reads instead inside getBatch
  end
  for k,v in pairs(keys) do
    print('reading ' .. v)
    self[v] = self.h5_file:read('/' .. v):all()
  end

  -- open region proposals file for reading
  if string.len(self.proposal_regions_h5) > 0 then
    print('DataLoader loading objectness boxes from h5 file: ', opt.proposal_regions_h5)
    self.obj_boxes_file = hdf5.open(opt.proposal_regions_h5, 'r')
    self.obj_img_to_first_box = self.obj_boxes_file:read('/img_to_first_box'):all()
    self.obj_img_to_last_box = self.obj_boxes_file:read('/img_to_last_box'):all()
  end
  
  -- extract image size from dataset
  local images_size = self.h5_file:read('/images'):dataspaceSize()
  assert(#images_size == 4, '/images should be a 4D tensor')
  assert(images_size[3] == images_size[4], 'width and height must match')
  self.num_images = images_size[1]
  self.num_channels = images_size[2]
  self.max_image_size = images_size[3]

  if self.h5_read_all then
    print('closing h5 file, everything is in RAM')
    self.h5_file:close() -- we can close the h5_file, we read everything in
  end

  -- extract some attributes from the data
  self.num_regions = self.boxes:size(1)
  self.vgg_mean = torch.FloatTensor{103.939, 116.779, 123.68} -- BGR order
  self.vgg_mean = self.vgg_mean:view(1,3,1,1)
  self.seq_length = self.labels:size(2)

  -- set up index ranges for the different splits
  self.train_ix = {}
  self.val_ix = {}
  self.test_ix = {}
  if self.use_split_indicator then
    print('using the split indicator array to compute the data splits.')
    for i=1,self.num_images do
      if self.split[i] == 0 then table.insert(self.train_ix, i) end
      if self.split[i] == 1 then table.insert(self.val_ix, i) end
      if self.split[i] == 2 then table.insert(self.test_ix, i) end
    end
  else
    print('setting splits according to train_frac/val_frac')
    local split_fractions = {opt.train_frac, opt.val_frac, 1.0 - opt.train_frac - opt.val_frac}
    local b1 = math.ceil(self.num_images * split_fractions[1])
    local b2 = math.ceil(self.num_images * (split_fractions[1] + split_fractions[2]))
    for i=1,self.num_images do
      if i <= b1 then 
        table.insert(self.train_ix, i)
      elseif i <= b2 then
        table.insert(self.val_ix, i)
      else
        table.insert(self.test_ix, i)
      end
    end
  end
  self.iterators = {[0]=1,[1]=1,[2]=1} -- iterators (indices to split lists) for train/val/test
  print(string.format('assigned %d/%d/%d to train/val/test.', #self.train_ix, #self.val_ix, #self.test_ix))

  print('initialized DataLoader:')
  print(string.format('#images: %d, #regions: %d, sequence max length: %d', 
                      self.num_images, self.num_regions, self.seq_length))
end

function DataLoader:getImageMaxSize()
  return self.max_image_size
end

function DataLoader:getSeqLength()
  return self.seq_length
end

function DataLoader:getVocabSize()
  return self.vocab_size
end

function DataLoader:getVocab()
  return self.info.idx_to_token
end

--[[
take a LongTensor of size DxN with elements 1..vocab_size+1 
(where last dimension is END token), and decode it into table of raw text sentences
--]]
function DataLoader:decodeSequence(seq)
  local D,N = seq:size(1), seq:size(2)
  local out = {}
  local itow = self.info.idx_to_token
  for i=1,N do
    local txt = ''
    for j=1,D do
      local ix = seq[{j,i}]
      if ix >= 1 and ix <= self.vocab_size then
        -- a word, translate it
        if j >= 2 then txt = txt .. ' ' end -- space
        txt = txt .. itow[tostring(ix)]
      else
        -- END token
        break
      end
    end
    table.insert(out, txt)
  end
  return out
end

-- split is an integer: 0 = train, 1 = val, 2 = test
function DataLoader:resetIterator(split)
  assert(split == 0 or split == 1 or split == 2, 'split must be integer, either 0 (train), 1 (val) or 2 (test)')
  self.iterators[split] = 1
end

--[[
  split is an integer: 0 = train, 1 = val, 2 = test
  Returns a batch of data in two Tensors:
  - X (1,3,H,W) containing the image
  - B (1,R,4) containing the boxes for each of the R regions in xcycwh format
  - y (1,R,L) containing the (up to L) labels for each of the R regions of this image
  - info table of length R, containing additional information as dictionary (e.g. filename)
  The data is iterated linearly in order. Iterators for any split can be reset manually with resetIterator()
  Returning random examples is also supported by passing in .iterate = false in opt.
--]]
function DataLoader:getBatch(opt)
  local split = utils.getopt(opt, 'split', 0)
  local iterate = utils.getopt(opt, 'iterate', true)

  assert(split == 0 or split == 1 or split == 2, 'split must be integer, either 0 (train), 1 (val) or 2 (test)')
  local split_ix
  if split == 0 then split_ix = self.train_ix end
  if split == 1 then split_ix = self.val_ix end
  if split == 2 then split_ix = self.test_ix end
  assert(#split_ix > 0, 'split is empty?')
  
  -- pick an index of the datapoint to load next
  local ri -- ri is iterator position in local coordinate system of split_ix for this split
  local max_index = #split_ix
  if self.debug_max_train_images > 0 then max_index = self.debug_max_train_images end
  if iterate then
    ri = self.iterators[split] -- get next index from iterator
    local ri_next = ri + 1 -- increment iterator
    if ri_next > max_index then ri_next = 1 end -- wrap back around
    self.iterators[split] = ri_next
  else
    -- pick an index randomly
    ri = torch.random(max_index)
  end
  ix = split_ix[ri]
  assert(ix ~= nil, 'bug: split ' .. split .. ' was accessed out of bounds with ' .. ri)
  
  -- fetch the image
  local img
  if self.h5_read_all then
    img = self.images[{{ix,ix}}] -- read from RAM
  else
    img = self.h5_file:read('/images'):partial({ix,ix},{1,self.num_channels},
                            {1,self.max_image_size},{1,self.max_image_size})
  end

  -- crop image to its original width/height, get rid of padding, and dummy first dim
  img = img[{ 1, {}, {1,self.image_heights[ix]}, {1,self.image_widths[ix]} }]
  img = img:float() -- convert to float
  img = img:view(1, img:size(1), img:size(2), img:size(3)) -- batch the image
  img:add(-1, self.vgg_mean:expandAs(img)) -- subtract vgg mean

  -- fetch the corresponding labels array
  local r0 = self.img_to_first_box[ix]
  local r1 = self.img_to_last_box[ix]
  local label_array = self.labels[{ {r0,r1} }]
  local box_batch = self.boxes[{ {r0,r1} }]

  -- batch the boxes and labels
  assert(label_array:nDimension() == 2)
  assert(box_batch:nDimension() == 2)
  label_array = label_array:view(1, label_array:size(1), label_array:size(2))
  box_batch = box_batch:view(1, box_batch:size(1), box_batch:size(2))

  -- finally pull the info from json file
  local filename = self.info.idx_to_filename[tostring(ix)] -- json is loaded with string keys
  assert(filename ~= nil, 'lookup for index ' .. ix .. ' failed in the json info table.')
  local w,h = self.image_widths[ix], self.image_heights[ix]
  local ow,oh = self.original_widths[ix], self.original_heights[ix]
  local info_table = { {filename = filename, 
                        split_bounds = {ri, #split_ix},
                        width = w, height = h, ori_width = ow, ori_height = oh} }

  -- read regions if applicable
  local obj_boxes -- contains batch of x,y,w,h,score objectness boxes for this image
  if self.obj_boxes_file then
    local r0 = self.obj_img_to_first_box[ix]
    local r1 = self.obj_img_to_last_box[ix]
    obj_boxes = self.obj_boxes_file:read('/boxes'):partial({r0,r1},{1,5})
    -- scale boxes (encoded as xywh) into coord system of the resized image
    local frac = w/ow -- e.g. if ori image is 800 and we want 512, then we need to scale by 512/800
    local boxes_scaled = box_utils.scale_boxes_xywh(obj_boxes[{ {}, {1,4} }], frac)
    local boxes_trans = box_utils.xywh_to_xcycwh(boxes_scaled)
    obj_boxes[{ {}, {1,4} }] = boxes_trans
    obj_boxes = obj_boxes:view(1, obj_boxes:size(1), obj_boxes:size(2)) -- make batch
  end

  -- TODO: start a prefetching thread to load the next image ?
  return img, box_batch, label_array, info_table, obj_boxes
end
