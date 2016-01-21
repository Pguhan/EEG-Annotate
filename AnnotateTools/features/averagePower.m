%% extract feature: average power in a window
%  (apply sub-bands and sub-windows)
%
%  parameters:
%   EEG: EEG data (in EEGLAB structure)
%   subbands: frequency ranges of each band
%   filterOrder to define the width of transition bands
%   windowLength: the length of a window (in second)
%   subWindowLength: the length of sub-window (in second)
%   step: the gap between sub-windows (or windows) (in second)
%
%  output:
%    feature: structure
%      name       (name of the dataset in a way that allows one to identify it uniquely) <== if we save the features seperately for each dataset, we don't need this field.
%      channels   (vector of channel numbers corresponding to rows of feature vectors)
%      samples    (2D array feature size x number of features - features are in the columns)
%      labels     (a cell array containing a label for each feature.  We are going to allow strings rather than 0's and 1's --- this will allow for many different types of features.  For unknown data these will be empty)
%      times      (a vector of the starting time (in seconds) of the feature from the start of the dataset.)
%      headset    (name of the new headset, if empty, keep the original headset)
%      exclFlag   (a flag vector marking samples should be excluded
%      exclComment (exlain the reason of exclusion. i.e. overlap with boundary samples)
%    config: structure
%      subbands
%      filterOrder
%      windowLength
%      subLength
%      step
%
function [data, config] = averagePower(EEG, varargin)
try
    %Setup the parameters and reporting for the call   
    params = vargin2struct(varargin);  
    config.subbands = [0 50]; % defatult
    if isfield(params, 'subbands')
        config.subbands = params.subbands;
    end
    config.filterOrder = 500; % defatult 
    if isfield(params, 'filterOrder')
        config.filterOrder = params.filterOrder;
    end
    config.windowLength = 1.0; % defatult 
    if isfield(params, 'windowLength')
        config.windowLength = params.windowLength;
    end
    config.subLength = 0.25; % defatult 
    if isfield(params, 'subWindowLength')
        config.subLength = params.subWindowLength;
    end
    config.step = 0.25; % defatult 
    if isfield(params, 'step')
        config.step = params.step;
    end
    config.headset = [];    % default: do not interpolate data for new headset
    if isfield(params, 'targetHeadset')
        config.headset = params.targetHeadset; % generate data for new headset
    end
    
    % make new EEG which doesn't have external channels
    exFlag = zeros(length(EEG.chanlocs), 1);
    for c=1:length(EEG.chanlocs)
        if isempty(EEG.chanlocs(c).radius) % || (EEG.chanlocs(c).radius >= boundary)
            exFlag(c) = 1;  % external channels
        end
    end
    ch_externals = find(exFlag==1);
    EEGonly = pop_select(EEG, 'nochannel', ch_externals);    % exclude external channels

    % We assume three types of headsets
    % 1) biosemi 64 channel headset
    % 2) 256 channel headset which has 64 overlapped channels
    % 3) lower density channels
    % If no assumptions on the headsets, we need to interpolate all datasets.
    if ~isempty(config.headset)
        newchanlocs = readlocs(config.headset);
        if length(newchanlocs) == length(EEGonly.chanlocs)   % same biosemi 64 channel headset
            [newCh, originalCh] = getCommonChannel(newchanlocs, EEGonly.chanlocs);
            if isequal(newCh, originalCh)  % if two headsets are same
                EEGintp = EEGonly; % EEG of target headset = EEG of orginal headset
            else % if two headsets are not same
                EEGintp = interpmont(EEGonly, config.headset, 'nfids', 0);  % interpolate EEG data for new headset
            end
        elseif length(newchanlocs) < length(EEGonly.chanlocs)  % 256 channel headset
            EEGintp = interpmont(EEGonly, config.headset, 'nfids', 0);  % interpolate EEG data for new headset
%             [newCh, originalCh] = getCommonChannel(newchanlocs, EEGonly.chanlocs); % I was trying to use overlapped channels, but there were only 9 overlapped channels.
%             EEGint = EEGonly;
%             EEGint.nbchan = length(newchanlocs);
%             EEGint.data(newCh, :, :) = EEGonly.data(originalCh, :, :);
%             EEGint.chanlocs(newCh) = EEGonly.chanlocs(originalCh);
        else   % lower density
            EEGintp = interpmont(EEGonly, config.headset, 'nfids', 0);  % interpolate EEG data for new headset
        end
    end
    
    % fill the feature etc fields
    data.name = EEGintp.filename;
    data.channels = EEGintp.nbchan;

    % fill the feature samples, labels, and times field
    % features = accumulated data of (bandPass filtered average power) 
    [data.samples,  data.labels, data.times] = getSampleFeatures(EEGintp, config);

    % mask to exclude samples
    % 1) end of samples
    % 2) samples overlapped with boundary event
    [data.mask.index, data.mask.comments] = excludeMask(data, EEGintp);
    
catch mex
    errorMessages.averagePower = ['failed average power: ' getReport(mex)];
    errorMessages.status = 'unprocessed';
    EEG.etc.averagePower.errors = errorMessages;
    fprintf(2, '%s\n', errorMessages.averagePower);
end
end

% add comment to the comment list
% if the cell has already same comment, skip it.
function commentsNew = addComments(comments, index, comment)
    
    commentsNew = comments;
    
    for i=1:length(index)
        if isempty(commentsNew{index(i)})
            commentsNew{index(i)} = cellstr(comment);
        else
            bExist = false;
            for j=1:length(commentsNew{index(i)})
                if strcmp(commentsNew{index(i)}{j}, comment)
                    bExist = true;
                    break;
                end
            end
            if bExist == false
                commentsNew{index(i)} = [commentsNew{index(i)} cellstr(comment)];
            end
        end
    end
end

function [index, comments] = excludeMask(data, EEG)

    sampleNumb = size(data.samples, 2);

    index = zeros(1, sampleNumb);
    comments = cell(1, sampleNumb);    % comment explaining why the sample is excluded
    
    index(sampleNumb-6:sampleNumb) = 1;
    comments = addComments(comments, sampleNumb-6:sampleNumb, 'not enough sub-windows');
    
    boundaryFlag = zeros(1, sampleNumb);
    for e=1:length(EEG.event)
        if strcmp(EEG.event(e).type, 'boundary')
            beginBoundary = EEG.event(e).latency;
            endBoundary = beginBoundary + EEG.event(e).duration;
            boundaryFlag((beginBoundary <= data.times) & (data.times <= endBoundary)) = 1;
        end
    end
    
    % to exclude overlapped samples
    tempSampleIdx = find(boundaryFlag);
    index(tempSampleIdx) = 1;
    comments = addComments(comments, tempSampleIdx, 'boundary samples');
    
    excludeIdx = [];
    for offset = -7:7
        excludeIdx = cat(2, excludeIdx, tempSampleIdx+offset);
    end
    
    excludeIdx = unique(excludeIdx(:));
    excludeIdx(excludeIdx < 1) = [];
    excludeIdx(excludeIdx > sampleNumb) = [];
    
    index(excludeIdx) = 1;
    comments = addComments(comments, excludeIdx, 'overlapped with boundary');
end

function [sampleOut, labelOut, timeOut] = getSampleFeatures(EEGin, config)

    dataLength = size(EEGin.data, 2); 
    sRate = EEGin.srate;
    
    subLengthFrame = round(sRate*config.subLength); % sub window size in frame
    stepFrame = round(sRate*config.step);           % step in frame

    featureSubj = [];
    
    for m=1:size(config.subbands, 1) % for each sub-band
        subEEG = pop_eegfiltnew(EEGin, config.subbands(m, 1), config.subbands(m, 2), config.filterOrder); 
        
        data = subEEG.data;    % amplitude data
        % z-normalize so that it has zero-mean and unit std.
        % Becasue all channels has unit std, the different patterns in channel scales between subjects are reduced.
        data = (data - repmat(mean(data, 2), 1, size(data, 2))) ./ repmat(std(data, 0, 2), 1, size(data, 2));   
        data = data .^ 2;   % power data = amplitude ^ 2
        
        featureBand = [];
        windBegin = 1;
        windEnd = windBegin + subLengthFrame - 1;
        while windEnd < dataLength
            windFeature = mean(data(:, windBegin:windEnd), 2); % [64x1]
            featureBand = cat(2, featureBand, windFeature);
            windBegin = windBegin + stepFrame;
            windEnd = windBegin + subLengthFrame - 1;
        end
        featureSubj = cat(1, featureSubj, featureBand);
    end    
    
    subWindowNumb = config.windowLength / config.subLength;
    sampleOut = repmat(featureSubj, subWindowNumb, 1);

    dimension = size(featureSubj, 1);			% average Power for biosemi 64 channels, 8 sub-bands, 8 sub-windwos ==> (512)
    for b=2:size(config.subbands, 1)
        bandBegin = (b-1)*dimension+1;
        bandEnd = b*dimension;
        copyOffset = b-1;
        sampleOut(bandBegin:bandEnd, 1:end-copyOffset) = sampleOut(bandBegin:bandEnd, 1+copyOffset:end);
    end
    
    eventLabelString = getEventLabelInString(EEGin.event);            % event label in string format
    
    eventLatencySecond = [EEGin.event.latency]' ./ sRate;             % event.latency (in pnts) ==> seconds, note that sometimes the latency has decimal fraction.
    eventIndex = floor(eventLatencySecond ./ config.step) + 1;            % seconds ==> sub-window index
    
    labelOut = cell(1, size(sampleOut, 2));    % new label for samples
    for i=1:length(eventLabelString)
        if eventIndex(i) < length(labelOut)  
            if isempty(labelOut{eventIndex(i)})
                labelOut{eventIndex(i)} = eventLabelString(i);
            else
                labelOut{eventIndex(i)} = [labelOut{eventIndex(i)} eventLabelString(i)];       % if one sample has more than one events.
            end
        end
    end
    
    timeOut = (0:stepFrame:dataLength-1) ./ sRate;  % a vector of the starting time (in seconds)
    
%     sampleOut = samples(:, 1:end-7);
%     labelOut = labels(1:end-7);
end

function label = getEventLabelInString(event)

    % force string format event labels
    eventNumb = length(event);
    label = cell(eventNumb, 1); 
    for e=1:eventNumb
        if isnumeric(event(e).type)
            label{e} = num2str(event(e).type);
        elseif ischar(event(e).type)
            label{e} = event(e).type;
        else
            warning('unknown event type');
        end
    end
end

% fine the overlapped channels between two headsets
function [indexSmall, indexLarge] = getCommonChannel(chanlocsSmall, chanlocsLarge)
    indexSmall = [];
    indexLarge = [];
    
    for l=1:length(chanlocsLarge)
        for s=1:length(chanlocsSmall)
            if (chanlocsSmall(s).X == chanlocsLarge(l).X ...
                    && (chanlocsSmall(s).Y == chanlocsLarge(l).Y) ...
                    && (chanlocsSmall(s).Z == chanlocsLarge(l).Z))
                indexSmall = cat(1, indexSmall, s);
                indexLarge = cat(1, indexLarge, l);
            end
        end
    end
end