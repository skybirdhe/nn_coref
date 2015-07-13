require 'nn'
dofile('init.lua')
require 'cmd_adagrad'
require 'coref_utils'
require 'sparse_doc_data'

FullG2Model = {}
FullG2Model.__index = FullG2Model

torch.manualSeed(2)

function FullG2Model.make(pwD, hiddenPW, naD, hiddenUnary, hiddenOuter, fl, fn, wl) 
    torch.manualSeed(2)
    model = {}
    setmetatable(model,FullG2Model)
    model.hiddenPW = hiddenPW
    model.hiddenUnary = hiddenUnary
    model.hiddenOuter = hiddenOuter
    model.fl = fl
    model.fn = fn
    model.wl = wl

    -- make net for scoring non-anaphoric case
    local naNet = nn.Sequential() 
    naNet:add(nn.LookupTable(naD,hiddenUnary))   
    naNet:add(nn.Sum(1))
    naNet:add(nn.Add(hiddenUnary)) -- add a bias
    naNet:add(nn.Tanh())
    naNet:add(nn.Linear(hiddenUnary,1))
    model.naNet = naNet 
    -- make sure contiguous, and do sparse Sutskever init while we're at it
    checkContigAndSutsInit(naNet,15)    
    model.nastates = {{},{},{},{}} 
    collectgarbage()

     -- make net for scoring anaphoric case
    local pwNet = nn.Sequential()
    local firstLayer = nn.ParallelTable() -- joins anaphoric and non-anaphoric features
    local anteNet = nn.Sequential()
    anteNet:add(nn.LookupTable(pwD,hiddenPW))
    anteNet:add(nn.Sum(1)) -- equivalent to a sparse Mat vec product
    anteNet:add(nn.Add(hiddenPW)) -- add a bias
    checkContigAndSutsInit(anteNet,15)
    collectgarbage()
    model.anteNet = anteNet -- just adding for convenience
    firstLayer:add(anteNet)
    
    -- anaNet has the same architecture as naNet
    local anaNet = nn.Sequential()
    anaNet:add(nn.LookupTable(naD,hiddenUnary))  
    anaNet:add(nn.Sum(1))
    anaNet:add(nn.Add(hiddenUnary)) -- add a bias
 
    -- naNet and anaNet should share first layer weight and bias...
    anaNet:share(naNet,'weight','bias','gradWeight','gradBias')
    firstLayer:add(anaNet)
    model.anaNet = anaNet
    pwNet:add(firstLayer)
    pwNet:add(nn.JoinTable(1,1))
    pwNet:add(nn.Tanh())
    pwNet:add(nn.Linear(hiddenPW+hiddenUnary,hiddenOuter))
    pwNet:add(nn.Tanh())
    pwNet:add(nn.Linear(hiddenOuter,1))
    model.pwNet = pwNet  
    -- initialize second layer
    sparseSutsMatInit(pwNet:get(4).weight,15,0.25)
    pwNet:get(4).bias:fill(0.5)
    pwNet:get(6).bias:fill(0.5)
    
    model.pwstates = {{},{},{},{},{},{}}
    collectgarbage()
    return model
end 


-- initializes with pre-trained parameters
function FullG2Model.preInit(hiddenOuter, fl, fn, wl, anteSerFi, naSerFi) 
    torch.manualSeed(2)
    model = {}
    setmetatable(model,FullG2Model)
    model.fl = fl
    model.fn = fn
    model.wl = wl
    model.hiddenOuter = hiddenOuter

    -- make net for scoring non-anaphoric case
    local naNet = torch.load(naSerFi)
    model.naNet = naNet 
    -- we keep the first layer, but reinitialize the last layer (v)
    naNet.modules[2] = nn.Sum(1) -- used to sum over 2, b/c were training in batches, but now just 1
    collectgarbage()
    -- re-initialize v (apart from bias) in the same way torch does...    
    local stdv = 1./math.sqrt(naNet:get(5).weight:size(2))
    naNet:get(5).weight:uniform(-stdv,stdv)
    naNet:get(5).bias:fill(0.5)
    checkContig(naNet)

    model.nastates = {{},{},{},{}}
    local naD = naNet:get(1).weight:size(1)
    model.hiddenUnary = naNet:get(1).weight:size(2)
    collectgarbage()

    -- make net for scoring anaphoric case
    local pwNet = nn.Sequential()
    local firstLayer = nn.ParallelTable() -- joins anaphoric and non-anaphoric features
    local anteNet = torch.load(anteSerFi)
    -- we only want the first 3 layers from pre-training
    anteNet.modules[4] = nil -- would've been Tanh
    anteNet.modules[5] = nil -- would've been final linear layer
    collectgarbage()
    checkContig(anteNet)
    model.hiddenPW = anteNet:get(1).weight:size(2)
    
    model.anteNet = anteNet -- just adding for convenience
    firstLayer:add(anteNet)
    -- anaNet has the same architecture as naNet
    local anaNet = nn.Sequential()
    anaNet:add(nn.LookupTable(naD,model.hiddenUnary))  
    anaNet:add(nn.Sum(1))
    anaNet:add(nn.Add(model.hiddenUnary)) -- add a bias
    
    -- naNet and anaNet should share first layer weight and bias...
    anaNet:share(naNet,'weight','bias','gradWeight','gradBias')
    firstLayer:add(anaNet)
    model.anaNet = anaNet
    pwNet:add(firstLayer)
    pwNet:add(nn.JoinTable(1,1))
    pwNet:add(nn.Tanh())
    pwNet:add(nn.Linear(model.hiddenPW+model.hiddenUnary,model.hiddenOuter))
    pwNet:add(nn.Tanh())
    pwNet:add(nn.Linear(model.hiddenOuter,1))
    model.pwNet = pwNet  
    
    -- initialize second layer
    sparseSutsMatInit(pwNet:get(4).weight,15,0.25)
    pwNet:get(4).bias:fill(0.5)
    pwNet:get(6).bias:fill(0.5)
    assert(pwNet:get(4).weight:isContiguous())
    assert(pwNet:get(4).bias:isContiguous())
    assert(pwNet:get(6).weight:isContiguous())
    
    model.pwstates = {{},{},{},{},{},{}}
    collectgarbage()
    return model
end 


function FullG2Model.load(pwFullSerFi, naFullSerFi, fl, fn, wl) 
    torch.manualSeed(2)
    model = {}
    setmetatable(model,FullG2Model)
    model.fl = fl
    model.fn = fn
    model.wl = wl

    local naNet = torch.load(naFullSerFi)
    model.naNet = naNet 
    model.nastates = {{},{},{},{}}
    local naD = naNet:get(1).weight:size(1)
    model.hiddenUnary = naNet:get(1).weight:size(2)
    collectgarbage()

    local pwNet = torch.load(pwFullSerFi)
    model.pwNet = pwNet
    model.anteNet = pwNet:get(1):get(1)
    model.hiddenPW = model.anteNet:get(1).weight:size(2)
    model.anaNet = pwNet:get(1):get(2)
    
    -- naNet and anaNet should share first layer weight and bias...
    model.anaNet:share(model.naNet,'weight','bias','gradWeight','gradBias')
    
    model.pwstates = {{},{},{},{},{},{}}
    collectgarbage()
    return model
end 


function FullG2Model:docGrad(d,pwData,anaData,clusts,pwnz,nanz)
    local numMents = pwData:numMents(d)
    local numPairs = (numMents*(numMents+1))/2
    local mistakes = {} -- keeps track of stuff we'll use to update gradient
    local deltTensor = torch.zeros(1) -- will hold delta for backprop
    -- calculate all pairwise scores in batch
    local scores = self:docBatchFwd(d,numMents,numPairs,pwData,anaData)

    for m = 2, numMents do -- ignore first guy; always NA       
        local start = ((m-1)*m)/2 -- one behind first pair for mention m
        -- score NA case separately
        scores[start+m] = self.naNet:forward(anaData:getFeats(d,m))
        -- pick a latent antecedent
        local late = m
        if clusts[d]:anaphoric(m) then
           late = maxGoldAnt(clusts[d],scores,m,start)
        end
                
        local pred = scores.cr.CR_mult_la_argmax(m,late,start,scores,clusts[d].clusts[clusts[d].m2c[m]],clusts[d].m2c,self.fl,self.fn,self.wl)
                
        local delt = clusts[d]:cost(m,pred,self.fl,self.fn,self.wl)
            
        if delt > 0 then
            deltTensor[1] = delt
            -- gradients involve adding predicted thing and subtracting latent thing
            if pred ~= m then
                -- run the predicted thing thru the net again so we can backprop
                self.pwNet:forward({pwData:getFeats(d,m,pred),anaData:getFeats(d,m)})
                self.pwNet:backward({pwData:getFeats(d,m,pred),anaData:getFeats(d,m)},deltTensor)
            else
                -- the predicted thing must have been m, which we already ran thru naNet
                self.naNet:backward(anaData:getFeats(d,m),deltTensor) 
            end
            -- same deal for subtracting latent thing
            if late ~= m then
                self.pwNet:forward({pwData:getFeats(d,m,late),anaData:getFeats(d,m)})
                self.pwNet:backward({pwData:getFeats(d,m,late),anaData:getFeats(d,m)},-deltTensor)            
            else
                self.naNet:backward(anaData:getFeats(d,m),-deltTensor)
            end
            table.insert(mistakes,{m,pred,late})
        end  
    end
    -- update nz idxs
    for i, mistake in ipairs(mistakes) do
        local ment = mistake[1]
        addKeys(anaData:getFeats(d,ment),nanz)
        if mistake[2] ~= ment then
            addKeys(pwData:getFeats(d,ment,mistake[2]),pwnz)
        end
        if mistake[3] ~= ment then
            addKeys(pwData:getFeats(d,ment,mistake[3]),pwnz)
        end
    end
end


function FullG2Model:docBatchFwd(d,numMents,numPairs,pwData,anaData)
    local onebuf = torch.ones(numPairs)
    local Z1 = torch.zeros(self.hiddenPW+self.hiddenUnary,numPairs) -- score everything at once
    -- start by adding biases
    Z1:sub(1,self.hiddenPW):addr(0,1,self.anteNet:get(3).bias,onebuf)
    Z1:sub(self.hiddenPW+1,self.hiddenPW+self.hiddenUnary):addr(0,1,self.naNet:get(3).bias,onebuf)
    -- now do sparse mult and tanh over all pairs: gives something hidden_pairwise x numPairs
    Z1.cr.CR_fm_layer1(Z1,self.anteNet:get(1).weight,pwData.feats,pwData.mentStarts,self.naNet:get(1).weight,anaData.feats,anaData.mentStarts,pwData.docStarts[d],anaData.docStarts[d],numMents)
    -- start with bias
    local Z2 = torch.ger(self.pwNet:get(4).bias, onebuf)
    Z2:addmm(self.pwNet:get(4).weight,Z1) -- W Z1 + b
    Z2:tanh()
    local scores = torch.mv(Z2:t(),self.pwNet:get(6).weight[1])
    scores:add(self.pwNet:get(6).bias[1])
    return scores
end


function train(pwData,anaData,clusts,pwDevData,anaDevData,hiddenPW,hiddenUnary,
                            hiddenOuter,fl,fn,wl,eta1,eta2,lamb,nEpochs,save,savePfx,PT,
                            anteSerFi,anaSerFi)
   local PT = PT or true -- whether to initialize with pretrained params
   local nEpochs = nEpochs or 5
   local serFi = string.format("models/%s_%d-%f-%f-%f.model", savePfx, hiddenOuter, fl, fn, wl)

   -- reset everything
   torch.manualSeed(2)
   local fm = nil
   if PT then
     fm = FullG2Model.preInit(hiddenOuter, fl, fn, wl, anteSerFi, anaSerFi)
   else
     fm = FullG2Model.make(pwData.maxFeat, hiddenPW, anaData.maxFeat, hiddenUnary, hiddenOuter, fl, fn, wl)
   end
   collectgarbage()

   for n = 1, nEpochs do
      print("epoch: " .. tostring(n))
      -- use document sized minibatches
      for d = 1, pwData.numDocs do
         if d % 200 == 0 then
            print("doc " .. tostring(d))
            collectgarbage()
         end 
         local pwnz = {}
         local nanz = {}     
         fm.pwNet:zeroGradParameters()
         fm.naNet:zeroGradParameters()       
         fm:docGrad(d,pwData,anaData,clusts,pwnz,nanz)
         
         -- update pw parameters
         colTblCmdAdaGrad(fm.anteNet:get(1).weight, fm.anteNet:get(1).gradWeight, pwnz,
                     eta1, lamb, fm.pwstates[1])
         cmdAdaGradC(fm.anteNet:get(3).bias, fm.anteNet:get(3).gradBias, 
                     eta1, lamb, fm.pwstates[2])  
         cmdAdaGradC(fm.pwNet:get(4).weight, fm.pwNet:get(4).gradWeight, 
                     eta2, lamb, fm.pwstates[3])                         
         cmdAdaGradC(fm.pwNet:get(4).bias, fm.pwNet:get(4).gradBias, 
                     eta2, lamb, fm.pwstates[4])
         cmdAdaGradC(fm.pwNet:get(6).weight, fm.pwNet:get(6).gradWeight, 
                     eta2, lamb, fm.pwstates[5])
         cmdAdaGradC(fm.pwNet:get(6).bias, fm.pwNet:get(6).gradBias, 
                     eta2, lamb, fm.pwstates[6])

         -- update ana parameters                                   
         colTblCmdAdaGrad(fm.naNet:get(1).weight, fm.naNet:get(1).gradWeight, nanz,
                     eta1, lamb, fm.nastates[1])
         cmdAdaGradC(fm.naNet:get(3).bias, fm.naNet:get(3).gradBias, 
                     eta1, lamb, fm.nastates[2])
         cmdAdaGradC(fm.naNet:get(5).weight, fm.naNet:get(5).gradWeight, 
                     eta2, lamb, fm.nastates[3])
         cmdAdaGradC(fm.naNet:get(5).bias, fm.naNet:get(5).gradBias, 
                     eta2, lamb, fm.nastates[4])                       
      end

      if save then
        print("overwriting params...")
        if PT then
          torch.save(serFi.."-full_g2_PT-pw",fm.pwNet)
          torch.save(serFi.."-full_g2_PT-na",fm.naNet)
        else
          torch.save(serFi.."-full_g2_RI-pw",fm.pwNet)
          torch.save(serFi.."-full_g2_RI-na",fm.naNet)
        end
     end

      collectgarbage()
   end          
end


function FullG2Model:writeBPs(pwDevData,anaDevData,bpfi)
    local bpfi = bpfi or "bps/dev.bps"
    local ofi = assert(io.open(bpfi,"w"))
    for d = 1, pwDevData.numDocs do
        if d % 100 == 0 then
            print("dev doc " .. tostring(d))
            collectgarbage()
        end
        local numMents = anaDevData:numMents(d)
        local numPairs = (numMents*(numMents+1))/2
        ofi:write("0") -- predict first thing links to itself always
        local scores = self:docBatchFwd(d,numMents,numPairs,pwDevData,anaDevData)
        for m = 2, numMents do
            local start = ((m-1)*m)/2 
            -- rescore NA case (batch only does anaphoric cases)
            scores[start+m] = self.naNet:forward(anaDevData:getFeats(d,m))
            local _, pred = torch.max(scores:sub(start+1,start+m),1)
            ofi:write(" ",tostring(pred[1]-1))
        end 
        ofi:write("\n")
    end
    ofi:close()
end

function FullG2Model:docLoss(d,pwData,anaData,clusts)
    local loss = 0
    local numMents = pwData:numMents(d)
    local numPairs = (numMents*(numMents+1))/2
    local scores = self:docBatchFwd(d,numMents,numPairs,pwData,anaData)
    for m = 2, numMents do -- ignore first guy; always NA
        local start = (m*(m-1))/2
        scores[start+m] = self.naNet:forward(anaData:getFeats(d,m))
        local late = m
        if clusts[d]:anaphoric(m) then
           late = maxGoldAnt(clusts[d],scores,m,start)
        end
        local pred = scores.cr.CR_mult_la_argmax(m,late,start,scores,clusts[d].clusts[clusts[d].m2c[m]],clusts[d].m2c,self.fl,self.fn,self.wl)        
        local delt = clusts[d]:cost(m,pred,self.fl,self.fn,self.wl)
        if delt > 0 then
            loss = loss + delt*(1 + scores[start+pred] - scores[start+late])
        end
    end
    return loss
end


cmd = torch.CmdLine()
cmd:text()
cmd:text()
cmd:text('Training full g2 model')
cmd:text()
cmd:text('Options')
cmd:option('-hiddenUnary', 128, 'Anaphoricity network hidden layer size')
cmd:option('-hiddenPairwise', 700, 'Pairwise network hidden layer size')
cmd:option('-hiddenOuter', 128, 'Second/joint hidden layer size')
cmd:option('-trainClustFile', '../TrainOPCs.txt', 'Train Oracle Predicted Clustering File')
cmd:option('-pwTrFeatPrefix', 'train_basicp', 'Expects train pairwise features in <pwTrFeatPfx>-pw-*.h5')
cmd:option('-pwDevFeatPrefix', 'dev_basicp', 'Expects dev pairwise features in <pwDevFeatPfx>-pw-*.h5')
cmd:option('-anaTrFeatPrefix', 'train_basicp', 'Expects train anaphoricity features in <anaTrFeatPfx>-na-*.h5')
cmd:option('-anaDevFeatPrefix', 'dev_basicp', 'Expects dev anaphoricity features in <anaDevFeatPfx>-na-*.h5')
cmd:option('-antePTSerFile','models/basicp_700.model-pw-0.100000-0.000010','Path to pretrained antecedent network')
cmd:option('-anaphPTSerFile','models/basicp_128.model-na-0.100000-0.000010','Path to pretrained anaphoricity network')
cmd:option('-randomInit', false, 'Randomly initialize parameters')
cmd:option('-nEpochs', 6, 'Number of epochs to train')
cmd:option('-fl', 0.5, 'False Link cost')
cmd:option('-fn', 1.2, 'False New cost')
cmd:option('-wl', 1, 'Wrong Link cost')
cmd:option('-t', 8, "Number of threads")
cmd:option('-eta1', 0.1, 'Adagrad learning rate for first layer')
cmd:option('-eta2', 0.001, 'Adagrad learning rate for second layer')
cmd:option('-lamb', 0.0001, 'L1 regularization coefficient')
cmd:option('-save', false, 'Save model')
cmd:option('-savePrefix', 'basicp', 'Prefixes saved model with this')
cmd:option('-loadAndPredict', false, 'Load full model and predict (on dev or test)')
cmd:option('-pwFullSerFile', 'models/basicp_128-0.500000-1.200000-1.000000.model-full_g2_PT-pw', 'Path to saved pairwise network portion of trained model')
cmd:option('-anaFullSerFile', 'models/basicp_128-0.500000-1.200000-1.000000.model-full_g2_PT-na', 'Path to  saved anaphoricity portion of trained model')
cmd:text()

-- Parse input options
opts = cmd:parse(arg)

if opts.t > 0 then
    torch.setnumthreads(opts.t)
end
print("Using " .. tostring(torch.getnumthreads()) .. " threads")


function main()
    if not opts.loadAndPredict then -- if training, get train data
       local pwTrData = SpDMPWData.loadFromH5(opts.pwTrFeatPrefix)
       print("read pw train data")
       print("max pw feature is: " .. pwTrData.maxFeat)
       local anaTrData = SpDMData.loadFromH5(opts.anaTrFeatPrefix)
       print("read anaph train data")
       print("max ana feature is: " .. anaTrData.maxFeat)       
       local trClusts = getOPCs(opts.trainClustFile,anaTrData)
       print("read train clusters")   
       local pwDevData = SpDMPWData.loadFromH5(opts.pwDevFeatPrefix)
       print("read pw dev data")
       local anaDevData = SpDMData.loadFromH5(opts.anaDevFeatPrefix)
       print("read anaph dev data")  
       train(pwTrData,anaTrData,trClusts,pwDevData,anaDevData,opts.hiddenPairwise,
            opts.hiddenUnary,opts.hiddenOuter,opts.fl,opts.fn,opts.wl,opts.eta1,opts.eta2,
            opts.lamb,opts.nEpochs,opts.save,opts.savePrefix,
            (not opts.randomInit),opts.antePTSerFile,opts.anaphPTSerFile)         
    else
       local pwDevData = SpDMPWData.loadFromH5(opts.pwDevFeatPrefix)
       print("read pw dev data")
       local anaDevData = SpDMData.loadFromH5(opts.anaDevFeatPrefix)
       print("read anaph dev data")
       local fm = FullG2Model.load(opts.pwFullSerFile, opts.anaFullSerFile)
       fm:writeBPs(pwDevData,anaDevData,"bps/load_and_pred.bps")
    end
end

main()

