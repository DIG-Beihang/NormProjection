-------------------------------------------------------------------------------------------------
require 'xlua'
require 'torch'
require 'math'
require 'nn'
require 'optim'
require 'gnuplot'
require 'dataset-mnist'


require 'image'

require 'models/MLP/model_NP'
--require 'models/MLP/model_basic'
local c = require 'trepl.colorize'
------------------------------------------------------------------------------
-- INITIALIZATION AND DATA
------------------------------------------------------------------------------

-- threads
threadNumber=1
torch.setnumthreads(threadNumber)

cmd = torch.CmdLine()
cmd:text()
cmd:text()
cmd:text()
cmd:text('Options')

cmd:option('-model_method','sgd','the methods: options:WNorm, WBN_Row,WCBN_Row,WGC,WO_Row,WO_Row_batch,WOBN_Row')
cmd:option('-mode_nonlinear',2,'nonlinear module: 1 indicates tanh, 0 indicates sigmoid, 2 indecates Relu')
cmd:option('-max_epoch',40,'maximum number of iterations')
cmd:option('-n_hidden_number',128,'the dimension of the hidden laysers')
cmd:option('-save',"log_MLP_MNIST" ,'subdirectory to save logs')
cmd:option('-inputScaled',true,'whether preoprocess the input, scale to (0,1)')
cmd:option('-inputCentered',true,'whether preoprocess the input, minus the mean')

cmd:option('-batchSize',256,'the number of examples per batch')
cmd:option('-learningRate',0.3,'learning rate')
cmd:option('-weightDecay',0,'weight Decay for regularization')
cmd:option('-momentum',0,'momentum')


cmd:option('-optimization','simple','the methods: options:adam,simple,rms,adagrad,lbfgs')
---------------for nnn BatchLinear_NoBP realted method----------------
cmd:option('-T',100,'the interval to update the coefficient')
cmd:option('-epcilo',1e-3,'the revision term for natural neural network')
cmd:option('-seed',1,'the random seed')
cmd:option('-orth_intial',false,'the random seed')
cmd:option('-dropout',0,'the random seed')

cmd:option('-modelSave',1,'the initial value for BN scale')
cmd:option('-learningRateDecayRatio',0.2,'initial learning rate')
cmd:option('-printInterval',10,'initial learning rate')


cmd:text()

-- parse input params
opt = cmd:parse(arg)

--opt.rundir = cmd:string('log_MLP_8Final', opt, {dir=true})
--paths.mkdir(opt.rundir)

-- create log file
--cmd:log(opt.rundir .. '/log', opt)
torch.manualSeed(opt.seed)    -- fix random seed so program runs the same every time
--opt.orth_intial=true
opt.train_size = 60000  -- set to 0 or 60000 to use all 60000 training data
opt.test_size = 0      -- 0 means load all data
opt.Ns=0.1*opt.T --used for nnn and BN_NoBP method.

--opt.printInterval=1


if opt.optimization == 'lbfgs' then
  opt.optimState = {
    learningRate = opt.learningRate,
    maxIter = 2,
    nCorrection = 10
  }
 optimMethod = optim.lbfgs
elseif opt.optimization == 'simple' then
  opt.optimState = {
    learningRate =opt.learningRate,
    weightDecay = opt.weightDecay,
    momentum = opt.momentum,
    learningRateDecay = 0
  }
 optimMethod = optim.sgd
elseif opt.optimization == 'adagrad' then
  opt.optimState = {
    learningRate = opt.learningRate,
  }
 optimMethod = optim.adagrad
elseif opt.optimization == 'rms' then
  opt.optimState = {
    learningRate = opt.learningRate,
    alpha=0.9
  }
 optimMethod = optim.rmsprop
 elseif opt.optimization == 'adam' then
  opt.optimState = {
    learningRate = opt.learningRate
  }
 optimMethod = optim.adam
elseif opt.optimization == 'adadelta' then
  opt.optimState = {
    learningRate = opt.learningRate
  }
 optimMethod = optim.adadelta
else
  error('Unknown optimizer')
end

mnist.download()   
-- load dataset using dataset-mnist.lua into tensors (first dim of data/labels ranges over data)
 function load_dataset(train_or_test, count)
    -- load
    local data
    if train_or_test == 'train' then
        data = mnist.loadTrainSet(count, {32, 32})
    else
        data = mnist.loadTestSet(count, {32, 32})
    end

    -- shuffle the dataset
    local shuffled_indices = torch.randperm(data.data:size(1)):long()
    -- creates a shuffled *copy*, with a new storage
    data.data = data.data:index(1, shuffled_indices):squeeze()
    data.labels = data.labels:index(1, shuffled_indices):squeeze()
   
    
    
   data.data = data.data:reshape(data.data:size(1), 32*32)
    return data
end


   trainData = load_dataset('train', opt.train_size)
   testData = load_dataset('test', opt.test_size)



opt.n_inputs=trainData.data:size(2) 
opt.n_outputs=trainData.labels:max()
 -- scale to (0,1)
 
if opt.inputScaled then
  for i=1, testData.data:size(1) do
   testData.data[i]:div(255)
  end

  for i=1, trainData.data:size(1) do
   trainData.data[i]:div(255)
  end

end



--o mean-----

if opt.inputCentered then

  local mean =  trainData.data:mean()
  trainData.data:add(-mean)
 
  local mean =  testData.data:mean()
  testData.data:add(-mean)
end

----------------------------------------------------------------------


function evaluateAccuracy(prediction, y)
    -- load
  correct=0;
  length=y:size(1)
  for i=1, length do
    if prediction[i][1]==y[i] then--the type of prediction is 2 D Tensor, y is vector
      correct=correct+1;
    end
      
  end
    accuracy=correct/length
    return accuracy
end



model, criterion = create_model(opt)

 
 confusion = optim.ConfusionMatrix(opt.n_outputs)
print('Will save at '..opt.save)
paths.mkdir(opt.save)

log_name=opt.model_method..'_'..opt.optimization..'_lr'..opt.learningRate..'.log'

testLogger = optim.Logger(paths.concat(opt.save, log_name))
testLogger:setNames{'% mean class accuracy (train set)', '% mean class accuracy (test set)'}
testLogger.showPlot = false
------------------------------------------------------------------------------
-- TRAINING
------------------------------------------------------------------------------

 parameters, gradParameters = model:getParameters()
print(model)
------------------------------------------------------------------------
-- training       
------------------------------------------------------------------------

 function train()
  model:training()
  epoch = epoch or 1

 
  print(c.blue '==>'.." online epoch # " .. epoch .. ' [batchSize = ' .. opt.batchSize .. ']')

  local targets = torch.Tensor(opt.batchSize)
  local indices = torch.randperm(trainData.data:size(1)):long():split(opt.batchSize)
  -- remove last element so that all the batches have equal size
  indices[#indices] = nil

 -- local tic = torch.tic()
  for t,v in ipairs(indices) do
    xlua.progress(t, #indices)

    local inputs = trainData.data:index(1,v)
    targets:copy(trainData.labels:index(1,v))

    local feval = function(x)
      if x ~= parameters then parameters:copy(x) end
      gradParameters:zero()
      
      local outputs = model:forward(inputs)
      local f = criterion:forward(outputs, targets)
      local df_do = criterion:backward(outputs, targets)
      model:backward(inputs, df_do)
     --print(outputs)
      confusion:batchAdd(outputs, targets)
      if iteration % opt.printInterval ==0 then
          print(string.format("minibatches processed: %6s, loss = %6.6f", iteration, f))
      end
      losses[#losses + 1] = f
--------------------------exit if loss exploding
      if f>1000 then

         print('loss is exploding, aborting.')
         os.exit()

      end




      timeCosts[#timeCosts+1]=torch.toc(start_time)
     -- print(string.format("time Costs = %6.6f", timeCosts[#timeCosts]))
      iteration=iteration+1
      return f,gradParameters
    end

   optimMethod (feval, parameters, opt.optimState)
   
 


      if ((string.match(opt.model_method,'PN'))  and iteration % opt.T ==0) then
    ------------------start:update the weightMatrix of SVB-------------------------------
        for k,v in pairs(model:findModules('nn.Linear_PN')) do
         -- print('update weight by PN:')
          v:updateWeight()
        end
     end

   
  end

  confusion:updateValids()
  print(('Train accuracy: '..c.cyan'%.2f'..' %%\t time: %.2f s'):format(
        confusion.totalValid * 100, torch.toc(start_time)))

  train_acc = confusion.totalValid * 100
  train_accus[#train_accus+1]=train_acc
  confusion:zero()
  
  
  epoch = epoch + 1
end


function test()

 model:evaluate()
  print(c.blue '==>'.." testing")
  local bs = 125
  for i=1,testData.data:size(1),bs do
    local outputs = model:forward(testData.data:narrow(1,i,bs))
    confusion:batchAdd(outputs, testData.labels:narrow(1,i,bs))
  end

  confusion:updateValids()
  print('Test accuracy:', confusion.totalValid * 100)
   test_accus[#test_accus+1]=confusion.totalValid * 100
  if testLogger then
    paths.mkdir(opt.save)
    testLogger:add{train_acc, confusion.totalValid * 100}
    testLogger:style{'-','-'}
    testLogger:plot()
   end
  confusion:zero()

end

iteration=0
losses={}
timeCosts={}

train_times={}
test_times={}


train_accus={}
test_accus={}
start_time=torch.tic()

Norm_GradWeight={}
Norm_Weight={}
Norm_GradInput={}
Norm_Output={}

for i=1,opt.max_epoch do
--  train()
--  test()
  local function t(f) local s = torch.Timer();f() return  s:time().real end

  local  train_time = t(train)
 train_times[#train_times+1]=train_time
 print('train Time:'..train_time)


  local  test_time = t(test)
  test_times[#test_times+1]=test_time
  print('test Time:'..test_time)



end

eig={}
dis={}

         for k,v in pairs(model:findModules('nn.Linear_SVD_debug')) do
         -- print(v.weight:size())
            table.insert(eig, v.eig)
            table.insert(dis, v.dis)
         end

results={}
opt.optimState=nil
results.opt=opt
results.losses=losses
results.train_accus=train_accus
results.test_accus=test_accus
results.eig=eig
results.dis=dis
--results.timeCosts=timeCosts
--results.testLogger=testLogger
--results.confusion=confusion
results.train_times=train_times
results.test_times=test_times

torch.save('result_MLP_MNIST_'..opt.model_method..
'_'..opt.optimization..'_b'..opt.batchSize..'_lr'..opt.learningRate..
'_nl'..opt.mode_nonlinear..'_mm'..opt.momentum..
'_ep'..opt.epcilo..'_T'..opt.T..
'_seed'..opt.seed..
'.dat',results)

 
