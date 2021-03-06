function out = Laplace_unfold(manual_masks,output_dir,labeldescription_fn,quantitative_dir,suppress_visuals)
% performs laplacian unfolding on the image of manually labelled structures
% manual_masks: BIDS directory containing manually labelled structures.
% This should contain the string 'label-HippUnfold'
% output_dir: BIDS output directory.
% labeldescription_fn(optional): 1 for basic structures, 2 for extended
% dummy labels, or specify custom .tsv file (see misc.labeldescription.tsv)
% quantitative_dir(optional): specify a directory of (registered) nifti
% images to map in unfolded space
% suppress_visuals(optional): 0(default) or 1 generate binned .nii
% gradients and morphometry/quantitative map figures

%% default arguments
if exist('labeldescription_fn')~=1 || isempty('labeldescription_fn')
    labeldescription_fn = 1;
end
if exist('quantitative_dir')~=1 || isempty('quantitative_dir')
    quantitative_dir = 'CoronalOblique0.3mm';
end
if exist('suppress_visuals')~=1 || isempty('suppress_visuals')
    suppress_visuals = 0;
end

%% get & format label description file
if labeldescription_fn==1
    labeldescription_fn = 'misc/labeldescription_basic.tsv';
elseif labeldescription_fn==2
    labeldescription_fn = 'misc/labeldescription_extendedSRLMdummylabels.tsv';
end
labeldescription = tdfread(labeldescription_fn);
labeldescription.label = cellstr(labeldescription.label);
labeldescription.boundary = cellstr(labeldescription.boundary);
labeldescription = table(labeldescription.boundary,labeldescription.value,labeldescription.label);

%% get output filename
subjects = ls(manual_masks);
subjects = strsplit(subjects)';
i = strfind(subjects, 'sub-');
i = cellfun('isempty', i);
subjects(i) = [];
subjects = sort(subjects);

for s=1:length(subjects)
    sub = subjects{s};
    [~,manual_fns] = system(['ls ' manual_masks '/' sub '/anat']);
    manual_fns = strsplit(manual_fns)';
    i = strfind(manual_fns, 'label-HippUnfold');
    i = cellfun('isempty', i);
    manual_fns(i) = [];
    
    for f=1:length(manual_fns)
        fn = manual_fns{f};
        fn = fn(1:strfind(fn,'.nii')-1);
        try
            fn(strfind(fn,'_roi'):end) = [];
        end
        output = [output_dir '/' sub '/anat/' fn];
        outd = strfind(output,'/');
        mkdir(output(1:outd(end)));
        

        %% load & crop manual segmentation
        origheader = load_nii([manual_masks '/' sub '/anat/' manual_fns{f}]);
        
        % crop around hippocampus by finding min and max in each direction that
        % contain non-zero label, and add one more voxel on each side just in case
        [x,y,z] = ind2sub(size(origheader.img),find(origheader.img>0));
        cropping = false(size(origheader.img)); %initialize
        cropping(min(x)-1:max(x)+1,min(y)-1:max(y)+1,min(z)-1:max(z)+1) = true;
        labelmap = zeros(max(x)-min(x)+3,max(y)-min(y)+3,max(z)-min(z)+3); %+3 because 2 come from expanding min and max domain by 1;
        labelmap(:) = origheader.img(cropping==1);
        origsz = size(origheader.img);
        origheader.img = [];
        
        % if left hippocampus, flip
        LR = output(strfind(output,'hemi-')+5);
        if LR=='L'
            labelmap = flipdim(labelmap,1); %flip on x (i.e. sagittally)
        end
        
        sz = size(labelmap);
        idxgm = find(ismember(labelmap,labeldescription.Var2(contains(cellstr(labeldescription.Var1),'domain'))));
        %note this is the domain for each gradient
        
        %% AP gradient:
        
        %Define ROIs
        sourceAP = find(ismember(labelmap,labeldescription.Var2(contains(cellstr(labeldescription.Var1),'APsource'))));
        sinkAP = find(ismember(labelmap,labeldescription.Var2(contains(cellstr(labeldescription.Var1),'APsink'))));
        
        Laplace_AP = laplace_solver(idxgm,sourceAP,sinkAP,50,[],sz);
        
        
        %% PD gradient
        
        % Define ROIs for Laplacian
        sourcePD = find(ismember(labelmap,labeldescription.Var2(contains(cellstr(labeldescription.Var1),'PDsource'))));
        sinkPD = find(ismember(labelmap,labeldescription.Var2(contains(cellstr(labeldescription.Var1),'PDsink'))));
        % check if SRLM covers subiculum
        
        if ~labeldescription.Var2(contains(cellstr(labeldescription.Var3),'SRLM')...
                & contains(cellstr(labeldescription.Var3),'dummy label'))
            extend_SRLM; %note: extended SRLM label number is 44
        end
        if isempty(sinkPD)
            %have to make these dummy labels ourselves
            automatic_DGgcl_approximation; %note: has to be run after Laplace_AP
            sinkPD=find(sink_main | sink_unc); %DGgcl
        end
        
        Laplace_PD = laplace_solver(idxgm,sourcePD,sinkPD,50,[],sz);
        
        %% Laminar gradient
        % compute thicknesses
        sourceIO = find(ismember(labelmap,[44;labeldescription.Var2(contains(cellstr(labeldescription.Var1),'IOsource'))]));
        sinkIO = find(ismember(labelmap,labeldescription.Var2(contains(cellstr(labeldescription.Var1),'IOsink'))));
        
        Laplace_IO = laplace_solver(idxgm,sourceIO,sinkIO,50,[],sz);
        
        %% orthogonalize Laplace_AP
        % gets the current edges of unfolded space, and then adjusts the boundary
        % conditions for the AP and PD gradients such that they always meet, making
        % them closer to orthogonal at the edges
        laplace_orthogonalize;
        
        %% solve again, using more iters and with orthogonalized boundary conditions
        Laplace_AP = laplace_solver(idxgm,sourceAP,sinkAP,1000,Laplace_AP,sz);
        Laplace_PD = laplace_solver(idxgm,sourcePD,sinkPD,1000,Laplace_PD,sz);
        
        %% clean up and save all variables
        
        bad2 = find(isnan(Laplace_AP) | isnan(Laplace_PD) | isnan(Laplace_IO) | isnan(idxgm));
        sprintf('removing %d bad voxels; sometimes happens due to islands in manual seg',length([bad;bad2]))
        Laplace_AP(bad) = []; Laplace_PD(bad) = []; Laplace_IO(bad) = []; idxgm(bad) = [];
        
        %% binned niftis for visualization
        if suppress_visuals==0
            
            origheader.img = zeros(origsz);
            
            out = zeros(sz);
            out(idxgm) = ceil(Laplace_AP*20);
            out(sinkAP) = 50;
            out(sourceAP) = 51;
            if LR=='L'
                out = flipdim(out,1); %flip on x (i.e. sagittally)
            end
            origheader.img(cropping==1) = out;
            save_nii(origheader,[output '_srcsnk-AP_PhiMap.nii.gz']);
            
            out = zeros(sz);
            out(idxgm) = ceil(Laplace_PD*20);
            out(sinkPD) = 50;
            out(sourcePD) = 51;
            if LR=='L'
                out = flipdim(out,1); %flip on x (i.e. sagittally)
            end
            origheader.img(cropping==1) = out;
            save_nii(origheader,[output '_srcsnk-PD_PhiMap.nii.gz']);
            
            out = zeros(sz);
            out(idxgm) = ceil(Laplace_IO*4);
            out(sourceIO) = 51;
            if LR=='L'
                out = flipdim(out,1); %flip on x (i.e. sagittally)
            end
            origheader.img(cropping==1) = out;
            save_nii(origheader,[output '_srcsnk-IO_PhiMap.nii.gz']);
        end
        
        %%
        save([output '_laplace.mat'],'origsz','output','LR','cropping','sub',...
            'origheader','idxgm','sz','Laplace_AP','Laplace_PD','Laplace_IO',...
            'sourceAP','sinkAP','sourcePD','sinkPD','sourceIO','sinkIO',...
            'manual_masks','output_dir','labeldescription','quantitative_dir',...
            'manual_fns');
        
        try
            Unfolded_morphometry
            Unfolded_qmapping
        end
    end
end

out = 1;
end
