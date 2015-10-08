local argparse = require 'argparse'

parser = argparse('Train a WordNet completion model')
parser:option '-d' :description 'dimensionality of embedding space' :default "100" :convert(tonumber)
parser:option '--epochs' :description 'number of epochs to train for ' :default "1" :convert(tonumber)
parser:option '--batchsize' :description 'size of minibatch to use' :default "1000" :convert(tonumber)
parser:option '--eval_freq' :description 'evaluation frequency' :default "100" :convert(tonumber)
parser:option '--lr' :description 'learning rate' :default "0.1" :convert(tonumber)
parser:option '--dataset' :description 'dataset to use' :default 'random'
parser:option '--margin' :description 'size of margin to use for contrastive learning'
parser:flag '--symmetric' : description 'use symmetric dot-product distance instance'

USE_CUDA = true
if USE_CUDA then
    require 'cutorch'
    require 'cunn'
end

local args = parser:parse()

require 'Dataset'
local datasets = torch.load('dataset/' .. args.dataset .. '.t7')
local train = datasets.train


local hyperparams = {
    D_embedding = args.d,
    word_embeddings = datasets.word_embeddings,
    symmetric = args.symmetric
}


require 'optim'
require 'HypernymScore'
local config = { learningRate = args.lr }

local hypernymNet = nn.HypernymScore(hyperparams)
local criterion = nn.HingeEmbeddingCriterion(args.margin)

----------------
-- EVALUATION --
----------------

local function cudify(input, target)
    if USE_CUDA then
        return {input[1]:cuda(), input[2]:cuda()}, target
    else
        return input, target
    end
end

-- returns optimal threshold, and classification at that threshold, for the given dataset
local function findOptimalThreshold(dataset, model)
    local input, target = cudify(dataset:all())
    local probs = model:forward(input):double()
    local sortedProbs, indices = torch.sort(probs, 1) -- sort in ascending order
    local sortedTarget = target:index(1, indices:long())
    local tp = torch.cumsum(sortedTarget)
    local invSortedTarget = torch.eq(sortedTarget, 0):double()
    local Nneg = invSortedTarget:sum() -- number of negatives
    local fp = torch.cumsum(invSortedTarget)
    local tn = fp:mul(-1):add(Nneg)
    local accuracies = tp:add(tn):div(sortedTarget:size(1))
    local bestAccuracy, i = torch.max(accuracies, 1)
    return sortedProbs[i[1]], bestAccuracy[1]
end

-- evaluate model at given threshold
local function evalClassification(dataset, model, threshold)
    local input, target = cudify(dataset:all())
    local probs = model:forward(input):double()

    local inferred = probs:le(threshold)
    local accuracy = inferred:eq(target:byte()):double():mean()
    return accuracy
end



--------------
-- TRAINING --
--------------
local parameters, gradients = hypernymNet:getParameters()

local best_accuracy = 0
local best_count = 0
local saved_weight
local count = 1
while train.epoch <= args.epochs do
    count = count + 1

    if not args.symmetric then
        hypernymNet.lookupModule.weight:cmax(0) -- make sure weights are positive
    end
    local function eval(x)
        hypernymNet:zeroGradParameters()
        local input, target = cudify(train:minibatch(args.batchsize))
        target:mul(2):add(-1) -- convert from 1/0 to 1/-1 convention
        local probs = hypernymNet:forward(input):double()
        local err = criterion:forward(probs, target)
        if count % 10 == 0 then
            print("Epoch " .. train.epoch .. " Batch " .. count .. " Error " .. err)
        end
        local gProbs = criterion:backward(probs, target):cuda()
        local _ = hypernymNet:backward(input, gProbs)
        return err, gradients
    end

    optim.adam(eval, parameters, config)

    if count % args.eval_freq == 0 then
        --print("Evaluating:")
        local threshold, accuracy = findOptimalThreshold(datasets.val1, hypernymNet)
        --print("Best accuracy " .. accuracy .. " at threshold " .. threshold)
        local real_accuracy = evalClassification(datasets.val2, hypernymNet, threshold)
        print("Accuracy " .. real_accuracy)
        if real_accuracy > best_accuracy then
            best_accuracy = real_accuracy
            best_count = count
            saved_weight = hypernymNet.lookupModule.weight:float()
        end
    end
end

print("Best accuracy was " .. best_accuracy .. " at batch #" .. best_count)
torch.save('weights_' .. string.format("%.2f", best_accuracy) .. '.t7', saved_weight)




