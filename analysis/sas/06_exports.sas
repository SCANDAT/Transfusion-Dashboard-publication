/* Scientific result exports.
   Full-precision model, robust-inference, aggregate-report and LOESS exports. Numeric representation is retained. Disclosure approval is separate.
   This file defines macros; use run.py to execute the analysis steps.
*/
%macro rbc_export_exact_csv(data=,fileref=);
 %global RBC_EXACT_CSV_OK RBC_EXACT_CSV_REASON;
 %let RBC_EXACT_CSV_OK=0;
 %let RBC_EXACT_CSV_REASON=NOT_COMPLETED;
 %local _rx_ds _rx_n _rx_i _rx_name _rx_type _rx_len _rx_close _rx_bad _rx_num _rx_owned _rx_reason _rx_ready;
 %let _rx_bad=0;
 %let _rx_owned=0;
 %let _rx_ds=0;
 %let _rx_ready=0;
 %let _rx_reason=;
 %let _rx_num=0;
 %if %sysfunc(prxmatch(%str(/^WORK\.[A-Za-z_][A-Za-z0-9_]{0,31}$/i),%superq(data))) ne 1
  or %sysfunc(prxmatch(%str(/^[A-Za-z_][A-Za-z0-9_]{0,7}$/),%superq(fileref))) ne 1 %then %do;
  %let _rx_reason=INVALID_STAGE_OR_FILEREF;
  %goto _rx_finish;
 %end;
 %if not %sysfunc(exist(&data,DATA)) or %sysfunc(exist(&data,VIEW))
  or %sysfunc(exist(work._rbc_exact_stage,DATA)) or %sysfunc(exist(work._rbc_exact_stage,VIEW))
  or %sysfunc(fileref(&fileref))>0 or %sysfunc(fexist(&fileref)) %then %do;
  %let _rx_reason=SOURCE_OR_DESTINATION_INVALID;
  %goto _rx_finish;
 %end;

 data _null_;
  length _rx_negzero 8;
  _rx_negzero=input('8000000000000000',hex16.);
  _rx_fraction=1;
  do _rx_index=1 to 13;_rx_fraction+_rx_index/(16**_rx_index);end;
  if upcase("&sysscp") ne 'WIN'
   or put(1,hex16.) ne '3FF0000000000000'
   or put(2,hex16.) ne '4000000000000000'
   or put(-1,hex16.) ne 'BFF0000000000000'
   or put(.5,hex16.) ne '3FE0000000000000'
   or put(_rx_fraction,hex16.) ne '3FF123456789ABCD'
   or put(constant('MACEPS'),hex16.) ne '3CB0000000000000'
   or put(constant('BIG'),hex16.) ne '7FEFFFFFFFFFFFFF'
   or put(input('0010000000000000',hex16.),hex16.) ne '0010000000000000'
   or put(input('0000000000000001',hex16.),hex16.) ne '0000000000000001'
   or put(_rx_negzero,hex16.) ne '8000000000000000' then do;
   call symputx('_rx_bad',1,'L');
  end;
 run;
 %if &_rx_bad or &syscc>4 or &syserr>4 %then %do;
  %let _rx_reason=NATIVE_IEEE_CONTRACT_FAILED; %goto _rx_finish;
 %end;
 %let _rx_ds=%sysfunc(open(&data,I));
 %if &_rx_ds=0 %then %do;
  %let _rx_reason=STAGE_OPEN_FAILED;
  %goto _rx_finish;
 %end;
 %let _rx_n=%sysfunc(attrn(&_rx_ds,NVARS));
 %if &_rx_n<1 or &_rx_n>32767 %then %let _rx_bad=1;
 %do _rx_i=1 %to &_rx_n;
  %local _rx_name&_rx_i _rx_type&_rx_i _rx_len&_rx_i;
  %let _rx_name&_rx_i=%sysfunc(varname(&_rx_ds,&_rx_i));
  %let _rx_type&_rx_i=%sysfunc(vartype(&_rx_ds,&_rx_i));
  %if &&_rx_type&_rx_i=N %then %let _rx_num=%eval(&_rx_num+1);
  %let _rx_len&_rx_i=%sysfunc(varlen(&_rx_ds,&_rx_i));
  %if %sysfunc(nvalid(&&_rx_name&_rx_i,V7)) ne 1
    or %upcase(%substr(&&_rx_name&_rx_i,1,%sysfunc(min(7,%length(&&_rx_name&_rx_i)))))=_RBCHEX %then %let _rx_bad=1;
 %end;
 %let _rx_close=%sysfunc(close(&_rx_ds));
 %let _rx_ds=0;
 %if &_rx_bad or &_rx_close ne 0 %then %do;
  %let _rx_reason=STAGE_SCHEMA_INVALID;
  %goto _rx_finish;
 %end;
 %let _rx_owned=1;
 data work._rbc_exact_stage;
  %do _rx_i=1 %to &_rx_n;
   %if &&_rx_type&_rx_i=N %then %do;length &&_rx_name&_rx_i $17;%end;
   %else %do;length &&_rx_name&_rx_i $&&_rx_len&_rx_i;%end;
  %end;
  set &data
  %if &_rx_num>0 %then %do;(rename=(
   %do _rx_i=1 %to &_rx_n;
    %if &&_rx_type&_rx_i=N %then %do;&&_rx_name&_rx_i=_rbchex&_rx_i%end;
   %end;
  ))%end;;
  %do _rx_i=1 %to &_rx_n;
   %if &&_rx_type&_rx_i=N %then %do;
    if missing(_rbchex&_rx_i) then &&_rx_name&_rx_i='.';
    else &&_rx_name&_rx_i=cats('H',put(_rbchex&_rx_i,hex16.));
    drop _rbchex&_rx_i;
   %end;
  %end;
  format _character_;
 run;
 %if &syscc>4 or &syserr>4 %then %do;
  %let _rx_reason=SAS_STEP_FAILED; %goto _rx_finish;
 %end;

 data _null_;
  file &fileref dsd dlm=',' lrecl=1048576 stopover;
  if _n_=1 then put
   %do _rx_i=1 %to &_rx_n; "&&_rx_name&_rx_i" %if &_rx_i<&_rx_n %then %do; "," %end; %end;
  ;
  set work._rbc_exact_stage;
  put %do _rx_i=1 %to &_rx_n; &&_rx_name&_rx_i ~ %end;;
 run;
 %if &syscc>4 or &syserr>4 %then %do;
  %let _rx_reason=SAS_STEP_FAILED; %goto _rx_finish;
 %end;
 %let _rx_ready=1;
 %_rx_finish:

 %if &_rx_ds>0 %then %let _rx_close=%sysfunc(close(&_rx_ds));
 %if &_rx_owned and %sysfunc(exist(work._rbc_exact_stage,DATA)) %then %do;
  proc datasets library=work nolist;delete _rbc_exact_stage;quit;
 %end;
 %if &_rx_ready and &syscc<=4 and &syserr<=4
   and not %sysfunc(exist(work._rbc_exact_stage,DATA)) %then %do;
  %let RBC_EXACT_CSV_OK=1;
  %let RBC_EXACT_CSV_REASON=EXPORTED;
 %end;
 %else %do;
  %if %length(&_rx_reason)=0 %then %let _rx_reason=EXPORT_OR_CLEANUP_FAILED;
  %let RBC_EXACT_CSV_REASON=&_rx_reason;
  %put NOTE: RBC_EXACT_EXPORT_FAILED &_rx_reason;
 %end;
%mend;

%macro rbc_archive_reject(reason=,on_error=ABORT);
    %global RBC_ARCHIVE_OK RBC_ARCHIVE_REASON;
    %let RBC_ARCHIVE_OK=0;
    %let RBC_ARCHIVE_REASON=&reason;
    %if %upcase(&on_error)=RETURN %then %put NOTE: RBC_ARCHIVE_REJECT &reason;
    %else %do;
        %put ERROR: RBC_ARCHIVE_GUARD &reason;
        %abort cancel;
    %end;
%mend;

%macro rbc_archive_schema(data=,chars=,nums=);
    %local dsid i variable position rc;
    %let dsid=%sysfunc(open(&data,i));
    %if &dsid=0 %then %do;
        %let RBC_ARCHIVE_REASON=INPUT_SCHEMA_INVALID;
        %return;
    %end;
    %do i=1 %to %sysfunc(countw(&chars));
        %let variable=%scan(&chars,&i);
        %let position=%sysfunc(varnum(&dsid,&variable));
        %if &position=0 %then %let RBC_ARCHIVE_REASON=INPUT_SCHEMA_INVALID;
        %else %if %sysfunc(vartype(&dsid,&position)) ne C %then
            %let RBC_ARCHIVE_REASON=INPUT_SCHEMA_INVALID;
    %end;
    %do i=1 %to %sysfunc(countw(&nums));
        %let variable=%scan(&nums,&i);
        %let position=%sysfunc(varnum(&dsid,&variable));
        %if &position=0 %then %let RBC_ARCHIVE_REASON=INPUT_SCHEMA_INVALID;
        %else %if %sysfunc(vartype(&dsid,&position)) ne N %then
            %let RBC_ARCHIVE_REASON=INPUT_SCHEMA_INVALID;
    %end;
    %let rc=%sysfunc(close(&dsid));
%mend;

%macro rbc_export_model_archive(outlib=,job_id=,exportlib=,on_error=ABORT);
    %local context_chars context roles i role chars nums fields allfields
        dsid rc n_rows n_columns n_categories model expected bad j field
        xvars dsvars column_count n_roles check_name status_fields export_path
        is_unavailable n_planned planned_pairs family_factor prior_decimal row1 row2 row3
        row4 row5 row6 row7 row8 row9 row10 row11 row12 row13 row14 row15 row16
        row17 row18 row19 row20 row21 row22 row23 row24 row25 col1 col2 col3 col4 col5 col6 col7 col8 col9
        col10 col11 col12 col13 col14 col15 col16 col17 col18 col19 col20 col21 col22 col23 col24 col25;
    %global RBC_ARCHIVE_OK RBC_ARCHIVE_REASON;
    %let RBC_ARCHIVE_OK=0;
    %let RBC_ARCHIVE_REASON=;
    %if not %sysmacexist(rbc_export_exact_csv) %then %do;
        %rbc_archive_reject(reason=EXACT_EXPORT_MODULE_REQUIRED,on_error=&on_error); %return;
    %end;
    %if %upcase(&on_error) ne ABORT and %upcase(&on_error) ne RETURN %then %do;
        %rbc_archive_reject(reason=INVALID_ERROR_MODE);
        %return;
    %end;
    %if %length(%superq(exportlib))=0 %then %let exportlib=&outlib;
    %if %length(%superq(outlib))=0 or %length(%superq(outlib))>8
        or %length(%superq(exportlib))=0 or %length(%superq(exportlib))>8
        or %length(%superq(job_id))=0 or %length(%superq(job_id))>12 %then %do;
        %rbc_archive_reject(reason=INVALID_LIBRARY_OR_JOB_NAME,on_error=&on_error);
        %return;
    %end;
    %if %sysfunc(nvalid(%superq(outlib),V7)) ne 1
        or %sysfunc(nvalid(%superq(exportlib),V7)) ne 1
        or %sysfunc(nvalid(%superq(job_id),V7)) ne 1 %then %do;
        %rbc_archive_reject(reason=INVALID_LIBRARY_OR_JOB_NAME,on_error=&on_error);
        %return;
    %end;
    %if %sysfunc(libref(&outlib)) ne 0 or %sysfunc(libref(&exportlib)) ne 0 %then %do;
        %rbc_archive_reject(reason=UNASSIGNED_ARCHIVE_LIBRARY,on_error=&on_error);
        %return;
    %end;
    %let export_path=%qsysfunc(pathname(&exportlib));
    %if %sysfunc(fileref(_rbcex))<=0 %then %do;
        %rbc_archive_reject(reason=EXPORT_FILEREF_COLLISION,on_error=&on_error);
        %return;
    %end;
    %let context_chars=RunId AnalysisSpecId CohortMode PopulationId FitId InputSnapshotId
        CodeHash ConfigHash DesignId ProfileId DFMethod JobID SubjectKeySource
        SubjectAlias DesignIdentityKind ProfileIdentityKind InferenceStatus;
    %let context=&context_chars BindingVersion;
    %let roles=identity columns anchor_levels anchor_diffs anchor_design score_design
        trajectory within_changes pairwise fitmetadata knots column_scale omnibus
        interaction_test categories profile fitstats covparms convergence solution inference_reference
        cat_availability contrast_plan family_plan job_status;
    %let n_roles=%sysfunc(countw(&roles));
    %rbc_archive_schema(data=&outlib..&job_id._identity,chars=&context_chars,nums=BindingVersion);
    %rbc_archive_schema(data=&outlib..&job_id._job_status,
        chars=JobStatus ReasonCode,nums=FitAttempted AvailableCategories PlanVersion);
    %rbc_archive_schema(data=&outlib..&job_id._family_plan,
        chars=Model FactorName,nums=PlannedCategories AvailableCategories PlannedPairs ActivePairs PlanVersion);
    %if %length(&RBC_ARCHIVE_REASON)>0 %then %do;
        %rbc_archive_reject(reason=INPUT_SCHEMA_INVALID,on_error=&on_error);
        %return;
    %end;
    %let bad=0;
    %let n_rows=0;
    data _null_;
        set &outlib..&job_id._identity end=last;
        if _n_ ne 1 or not prxmatch('/^[0-9a-fA-F]{32}$/',strip(RunId))
            or not prxmatch('/^[0-9a-fA-F]{64}$/',strip(CodeHash))
            or not prxmatch('/^[0-9a-fA-F]{64}$/',strip(ConfigHash))
            or CohortMode not in ('synthetic','development_sample','full_cohort')
            or upcase(JobID) ne upcase("&job_id") or BindingVersion ne 1
            or cmiss(of &context_chars)>0 then call symputx('bad',1,'L');
        if last then call symputx('n_rows',_n_,'L');
    run;
    %rbc_fit_check_sas(stage=ARCHIVE_CONTEXT_PRECHECK);
    %if &bad ne 0 or %superq(n_rows) ne 1 %then %do;
        %rbc_archive_reject(reason=INVALID_IDENTITY_CONTEXT,on_error=&on_error);
        %return;
    %end;
    %let n_rows=0;
    %let is_unavailable=0;
    data _null_;
        set &outlib..&job_id._job_status end=last;
        if _n_ ne 1 or PlanVersion ne 1 then call symputx('bad',1,'L');
        if JobStatus='FIT_CHECKS_PASSED' and ReasonCode='NONE' and FitAttempted=1 then
            call symputx('is_unavailable',0,'L');
        else if JobStatus='EXPECTED_UNAVAILABLE' and FitAttempted=0
            and ReasonCode in ('EMPTY_MODEL_INPUT','NO_OUTCOME_WINDOW_ROWS',
                'NO_COMPLETE_MODEL_ROWS','INSUFFICIENT_COMPLETE_ROWS','INSUFFICIENT_PERSONS',
                'DECLARED_REFERENCE_LEVEL_ABSENT','FACTOR_AVAILABLE_CATEGORIES_LT2') then
            call symputx('is_unavailable',1,'L');
        else call symputx('bad',1,'L');
        if last then call symputx('n_rows',_n_,'L');
    run;
    %rbc_fit_check_sas(stage=ARCHIVE_JOB_STATUS_PRECHECK);
    %if &bad ne 0 or &n_rows ne 1 %then %do;
        %rbc_archive_reject(reason=INVALID_JOB_STATUS,on_error=&on_error);
        %return;
    %end;
    %let n_rows=0;
    data _null_;
        set &outlib..&job_id._family_plan end=last;
        if _n_ ne 1 or PlanVersion ne 1 or Model not in ('BASE','FULL')
            or FactorName not in ('NONE','DonorHb_Cat','Storage_Cat','DonorSex',
                'DonorParity_Female','wdy_donation')
            or PlannedCategories<1 or PlannedCategories ne int(PlannedCategories)
            or AvailableCategories<0 or AvailableCategories>PlannedCategories
            or AvailableCategories ne int(AvailableCategories)
            or PlannedPairs ne PlannedCategories*(PlannedCategories-1)/2
            or ActivePairs ne AvailableCategories*(AvailableCategories-1)/2
            then call symputx('bad',1,'L');
        call symputx('n_planned',PlannedCategories,'L');
        call symputx('n_categories',AvailableCategories,'L');
        call symputx('planned_pairs',PlannedPairs,'L');
        call symputx('model',Model,'L');
        if last then call symputx('n_rows',_n_,'L');
    run;
    %rbc_fit_check_sas(stage=ARCHIVE_FAMILY_PRECHECK);
    %if &bad ne 0 or &n_rows ne 1 %then %do;
        %rbc_archive_reject(reason=INVALID_FAMILY_PLAN,on_error=&on_error);
        %return;
    %end;
    %if &is_unavailable=1 %then %do;
        %let roles=identity cat_availability contrast_plan family_plan job_status;
        %let n_roles=5;
        %let n_columns=0;
    %end;
    %else %do;
        %rbc_archive_schema(data=&outlib..&job_id._fitmetadata,
            chars=Model FitStatus DDFMethod,
            nums=N_DesignColumns N_Categories EngineRunChecksPassed ResidualDF);
        %if %length(&RBC_ARCHIVE_REASON)>0 %then %do;
            %rbc_archive_reject(reason=INPUT_SCHEMA_INVALID,on_error=&on_error);
            %return;
        %end;
        %let n_rows=0;
        data _null_;
            if _n_=1 then set &outlib..&job_id._identity(keep=DFMethod);
            set &outlib..&job_id._fitmetadata end=last;
            if _n_ ne 1 or FitStatus ne 'FIT_CHECKS_PASSED' or EngineRunChecksPassed ne 1
                or DDFMethod ne DFMethod or ResidualDF<=0
                or N_DesignColumns<1 or N_DesignColumns ne int(N_DesignColumns)
                or N_Categories ne &n_categories or N_Categories<1 or Model ne "&model"
                then call symputx('bad',1,'L');
            call symputx('n_columns',N_DesignColumns,'L');
            if last then call symputx('n_rows',_n_,'L');
        run;
        %rbc_fit_check_sas(stage=ARCHIVE_FIT_PRECHECK);
        %if &bad ne 0 or &n_rows ne 1 %then %do;
            %rbc_archive_reject(reason=FIT_NOT_COMPLETE,on_error=&on_error);
            %return;
        %end;
    %end;
    %let xvars=;
    %do j=1 %to &n_columns;
        %let xvars=&xvars RBCX&j;
    %end;

    %do i=1 %to &n_roles;
        %let role=%scan(&roles,&i);
        %let chars=; %let nums=; %let expected=-1;
        %if &role=identity %then %let expected=1;
        %else %if &role=columns %then %do;
            %let chars=ColumnName ParameterLabel;
            %let nums=InputPosition VariableType ColumnIndex; %let expected=&n_columns;
        %end;
        %else %if &role=anchor_levels %then %do;
            %let nums=AnchorID Estimate StdErr DF Lower Upper;
            %let expected=%eval(9*&n_categories);
        %end;
        %else %if &role=anchor_diffs %then %do;
            %let nums=LeftAnchor RightAnchor Estimate StdErr DF Lower Upper;
            %let expected=%eval(9*&n_categories*(9*&n_categories-1)/2);
        %end;
        %else %if &role=anchor_design %then %do;
            %let nums=AnchorID GridID CategoryIndex CategoryCode TimeFromTransfusion &xvars;
            %let expected=%eval(9*&n_categories);
        %end;
        %else %if &role=score_design %then %do;
            %let nums=GridID CategoryIndex CategoryCode TimeFromTransfusion &xvars;
            %let expected=%eval(1441*&n_categories);
        %end;
        %else %if &role=trajectory %then %do;
            %let chars=VitalCode FactorName Model;
            %let nums=GridID CategoryIndex CategoryCode TimeFromTransfusion Predicted StdErr
                Lower Upper Delta BaselineMinute; %let expected=%eval(1441*&n_categories);
        %end;
        %else %if &role=within_changes or &role=pairwise %then %do;
            %let chars=VitalCode FactorName Model Label RequestType;
            %let nums=AnchorA AnchorB CategoryA CategoryB CategoryCodeA CategoryCodeB
                Estimate StdErr DF PValue Lower Upper BeforeMinute AfterMinute;
            %let expected=&n_categories;
            %if &role=pairwise %then %do;
                %let chars=&chars PAdjustment CIAdjustment;
                %let nums=&nums FamilySize Rank PValue_Holm;
                %let expected=%eval(&n_categories*(&n_categories-1)/2);
            %end;
        %end;
        %else %if &role=fitmetadata %then %do;
            %let chars=VitalCode FactorName Model FitStatus ArchiveStatus DDFMethod
                CovarianceModel Optimizer ColumnScaleMethod KnotPolicy AdmissionCountStatus;
            %let nums=N_Scope N_Used N_Excluded_Missing N_Patients N_Events N_Admissions N_Categories
                N_DesignColumns N_Anchors N_RequestedEstimates BeforeMinute AfterMinute
                ResidualDF GConv AbsGConv MaxIter EngineRunChecksPassed; %let expected=1;
        %end;
        %else %if &role=knots %then %do;
            %let chars=EffectName VariableName Basis KnotSource BoundaryRole;
            %let nums=KnotNumber KnotValue ExpectedKnots;
            %let expected=13; %if &model=FULL %then %let expected=25;
        %end;
        %else %if &role=column_scale %then %do;
            %let nums=&xvars; %let expected=1;
        %end;
        %else %if &role=omnibus or &role=interaction_test %then %do;
            %let chars=VitalCode FactorName Model Estimand Label;
            %let nums=NumDF DenDF FValue ProbF;
            %let expected=0; %if &n_categories>1 %then %let expected=1;
        %end;
        %else %if &role=categories %then %do;
            %let nums=CategoryIndex CategoryCode N_Observations N_Patients N_Events;
            %let expected=&n_categories;
        %end;
        %else %if &role=profile %then %do;
            %let chars=PatientSex WardName;
            %let nums=PatientAge ICU_time RBC_Count;
            %if &model=FULL %then %let nums=&nums Crystalloid_1 Crystalloid_24 Pressors_1
                Pressors_24 Sedatives_1_bin Sedatives_24_bin;
            %let expected=1;
        %end;
        %else %if &role=fitstats %then %do;
            %let chars=Descr; %let nums=Value;
        %end;
        %else %if &role=covparms %then %do;
            %let chars=CovParm; %let nums=Estimate; %let expected=2;
        %end;
        %else %if &role=convergence %then %do;
            %let nums=Status; %let expected=1;
            %let dsid=%sysfunc(open(&outlib..&job_id._&role,i));
            %if &dsid>0 %then %do;
                %if %sysfunc(varnum(&dsid,pdG))>0 %then %let nums=&nums pdG;
                %let rc=%sysfunc(close(&dsid));
            %end;
        %end;
        %else %if &role=solution %then %do;
            %let chars=Effect; %let nums=Estimate StdErr DF tValue Probt;
            %let expected=&n_columns;
        %end;
        %else %if &role=cat_availability %then %do;
            %let chars=AvailabilityReason;
            %let nums=CategoryCode CategoryIndex N_Scope N_Observations N_Patients N_Events Available;
            %let expected=&n_planned;
        %end;
        %else %if &role=contrast_plan %then %do;
            %let chars=ContrastID ContrastType ExclusionReason FamilyID;
            %let nums=CategoryCodeA CategoryCodeB CategoryIndexA CategoryIndexB Planned Active BeforeMinute AfterMinute;
            %let expected=%eval(&n_planned+&planned_pairs);
        %end;
        %else %if &role=family_plan %then %do;
            %let chars=FamilyID FamilyRole FactorName Model VitalCode PAdjustment CIAdjustment FreezeStage;
            %let nums=PlannedCategories AvailableCategories PlannedPairs ActivePairs PlanVersion;
            %let expected=1;
        %end;
        %else %if &role=job_status %then %do;
            %let chars=JobStatus ReasonCode AdmissionCountStatus;
            %let nums=FitAttempted N_Input N_Scope N_Used N_Patients N_Events N_Admissions ReferenceCount AvailableCategories PlanVersion;
            %let expected=1;
        %end;
        %else %if &role=inference_reference %then %do;
            %let chars=CovarianceReference DFReference;
            %let nums=Alpha DF CriticalValue;
            %let expected=1;
        %end;
        %let fields=&chars &nums;
        %let allfields=&context &fields;
        %if &role=inference_reference %then %do;
            %let row&i=1;
            %let col&i=%sysfunc(countw(&allfields));
            %local fields&i;
            %let fields&i=&allfields;
        %end;
        %else %do;
        %rbc_archive_schema(data=&outlib..&job_id._&role,
            chars=&context_chars &chars,nums=BindingVersion &nums);
        %if %length(&RBC_ARCHIVE_REASON)>0 %then %do;
            %rbc_archive_reject(reason=INPUT_SCHEMA_INVALID,on_error=&on_error);
            %return;
        %end;
        %if not %sysfunc(exist(&outlib..&job_id._&role,DATA)) %then %do;
            %rbc_archive_reject(reason=ARCHIVE_ROLE_MUST_BE_DATA,on_error=&on_error);
            %return;
        %end;
        %let dsid=%sysfunc(open(&outlib..&job_id._&role,i));
        %let n_rows=%sysfunc(attrn(&dsid,NLOBS));
        %let rc=%sysfunc(close(&dsid));
        %if (&expected>=0 and &n_rows ne &expected) or (&expected<0 and &n_rows<1) %then %do;
            %rbc_archive_reject(reason=ROLE_CARDINALITY_INVALID,on_error=&on_error);
            %return;
        %end;
        %let row&i=&n_rows;
        %let col&i=%sysfunc(countw(&allfields));
        %local fields&i;
        %let fields&i=&allfields;
        %let bad=0;
        data _null_;
            if _n_=1 then set &outlib..&job_id._identity(keep=&context rename=(
                %do j=1 %to %sysfunc(countw(&context));
                    %let field=%scan(&context,&j); &field=_ARC_&field
                %end;
            ));
            set &outlib..&job_id._&role(keep=&context);
            %do j=1 %to %sysfunc(countw(&context));
                %let field=%scan(&context,&j);
                if &field ne _ARC_&field then call symputx('bad',1,'L');
            %end;
        run;
        %rbc_fit_check_sas(stage=ARCHIVE_ROLE_CONTEXT);
        %if &bad ne 0 %then %do;
            %rbc_archive_reject(reason=ROLE_CONTEXT_MISMATCH,on_error=&on_error);
            %return;
        %end;
        %if &role=columns %then %do;
            data _null_;
                set &outlib..&job_id._columns;
                if ColumnIndex ne _n_ or upcase(ColumnName) ne cats('RBCX',_n_)
                    or VariableType ne 1 then call symputx('bad',1,'L');
            run;
            %rbc_fit_check_sas(stage=ARCHIVE_COLUMN_ORDER);
            %if &bad ne 0 %then %do;
                %rbc_archive_reject(reason=DESIGN_COLUMN_ORDER_INVALID,on_error=&on_error);
                %return;
            %end;
        %end;
        %end;
    %end;
    %let bad=0;
    data _null_;
        %do i=1 %to %eval(&n_roles+1);
            %let role=archive_manifest;
            %if &i<=&n_roles %then %let role=%scan(&roles,&i);
            rc=filename('_rbcex',cats(pathname("&exportlib"),'/',"&job_id._&role..csv"));
            if rc ne 0 or fexist('_rbcex') then call symputx('bad',1,'L');
            rc=filename('_rbcex');
        %end;
    run;
    %rbc_fit_check_sas(stage=ARCHIVE_TARGET_PRECHECK);
    %if &bad ne 0 or %sysfunc(exist(&exportlib..&job_id._archive_manifest,DATA))
        or %sysfunc(exist(&exportlib..&job_id._archive_manifest,VIEW))
        or %sysfunc(exist(&exportlib..&job_id._inference_reference,DATA))
        or %sysfunc(exist(&exportlib..&job_id._inference_reference,VIEW)) %then %do;
        %rbc_archive_reject(reason=ARCHIVE_TARGET_EXISTS_OR_INVALID,on_error=&on_error);
        %return;
    %end;
    %if %sysfunc(exist(work._rbce_stage,DATA)) or %sysfunc(exist(work._rbce_manifest,DATA))
        or %sysfunc(exist(work._rbce_stage,VIEW)) or %sysfunc(exist(work._rbce_manifest,VIEW)) %then %do;
        %rbc_archive_reject(reason=EXPORT_SCRATCH_COLLISION,on_error=&on_error);
        %return;
    %end;

    %let prior_decimal=%sysfunc(getoption(decimalconv,keyword));
    options decimalconv=STDIEEE;
    %rbc_fit_check_sas(stage=ARCHIVE_DECIMAL_CONVERSION);
    %do i=1 %to &n_roles;
        %let role=%scan(&roles,&i);
        %if &role=inference_reference %then %do;
            data work._rbce_stage;
                length CovarianceReference $80 DFReference $16;
                if _n_=1 then set &outlib..&job_id._identity(keep=&context);
                set &outlib..&job_id._fitmetadata(keep=ResidualDF CovarianceModel DDFMethod);
                Alpha=.05; DF=ResidualDF; CriticalValue=TINV(1-Alpha/2,DF);
                CovarianceReference=CovarianceModel; DFReference=DDFMethod;
                if nmiss(Alpha,DF,CriticalValue)>0 or DF<=0 or CriticalValue<=0 then do;
                    put 'ERROR: RBC_ARCHIVE_GUARD INVALID_INFERENCE_REFERENCE';
                    abort cancel;
                end;
                keep &&fields&i;
                format _numeric_ e32.;
            run;
            data &exportlib..&job_id._inference_reference;
        retain &context;
                set work._rbce_stage;
            run;
        %end;
        %else %do;
            data work._rbce_stage;
                retain &&fields&i;
                set &outlib..&job_id._&role(keep=&&fields&i);
                format _numeric_ e32.;
            run;
        %end;
        data _null_;
            rc=filename('_rbcex',cats(pathname("&exportlib"),'/',"&job_id._&role..csv"));
            if rc ne 0 or fexist('_rbcex') then do;
                put 'ERROR: RBC_ARCHIVE_GUARD ARCHIVE_TARGET_CHANGED_DURING_EXPORT';
                abort cancel;
            end;
        run;
        filename _rbcex "%superq(export_path)/&job_id._&role..csv" encoding='utf-8';
        %rbc_export_exact_csv(data=work._rbce_stage,fileref=_rbcex);
        %if &RBC_EXACT_CSV_OK ne 1 %then %do;
            %goto exact_export_failed;
        %end;
        filename _rbcex clear;
        %rbc_fit_check_sas(stage=MODEL_ARCHIVE_CSV_EXPORT);
    %end;

    data work._rbce_manifest;
        retain &context;
        if _n_=1 then set &outlib..&job_id._identity(keep=&context);
        length Role $32 FileName $80 SourceMember SourceKind $32 NumericFormat $16 TextEncoding $8
            ExportStatus $24 ContentHashStatus $24;
        ArchiveVersion=1; NumericFormat='HEX16_IEEE754'; TextEncoding='UTF-8'; ExportStatus='EXPORTED_LOCAL_ONLY';
        ContentHashStatus='PENDING_EXTERNAL_HASH';
        %do i=1 %to &n_roles;
            %let role=%scan(&roles,&i);
            Role="&role"; FileName="&job_id._&role..csv";
            SourceMember="&job_id._&role";
            SourceKind='SOURCE_MODEL_TABLE';
            %if &role=inference_reference %then %do;
                SourceKind='DERIVED_MODEL_REFERENCE';
            %end;
            RowCount=&&row&i; ColumnCount=&&col&i;
            output;
        %end;
        stop;
        format _numeric_ e32.;
    run;
    data &exportlib..&job_id._archive_manifest;
        set work._rbce_manifest;
    run;
    data _null_;
        rc=filename('_rbcex',cats(pathname("&exportlib"),'/',"&job_id._archive_manifest.csv"));
        if rc ne 0 or fexist('_rbcex') then do;
            put 'ERROR: RBC_ARCHIVE_GUARD MANIFEST_TARGET_CHANGED_DURING_EXPORT';
            abort cancel;
        end;
    run;
    filename _rbcex "%superq(export_path)/&job_id._archive_manifest.csv" encoding='utf-8';
    %rbc_export_exact_csv(data=work._rbce_manifest,fileref=_rbcex);
    %if &RBC_EXACT_CSV_OK ne 1 %then %do;
        %goto exact_export_failed;
    %end;
    filename _rbcex clear;
    %rbc_fit_check_sas(stage=MODEL_ARCHIVE_MANIFEST_EXPORT);
    options &prior_decimal;
    %rbc_fit_check_sas(stage=ARCHIVE_DECIMAL_OPTION_RESTORE);
    proc datasets library=work nolist;
        delete _rbce_stage _rbce_manifest;
    quit;
    %let RBC_ARCHIVE_OK=1;
    %let RBC_ARCHIVE_REASON=EXPORTED_LOCAL_ONLY;
    %return;
%exact_export_failed:
     
    filename _rbcex clear;
    options &prior_decimal;
    proc datasets library=work nolist; delete _rbce_stage _rbce_manifest; quit;
    %rbc_archive_reject(reason=EXACT_NUMERIC_EXPORT_FAILED,on_error=&on_error);
%mend;

%macro rbc_cr2_export_reject(reason=);
  %global RBC_CR2_EXPORT_OK RBC_CR2_EXPORT_REASON;
  %let RBC_CR2_EXPORT_OK=0; %let RBC_CR2_EXPORT_REASON=&reason;
  %put NOTE: RBC_CR2_EXPORT_REJECT &reason;
%mend;
%macro rbc_cr2_white_role_fields(role=);
%let chars=; %let nums=; %let expected=-1;
%if &role=identity %then %do;
  %let chars=;
  %let nums=;
  %let expected=1;
%end;
%else %if &role=status %then %do;
  %let chars=IntegrationStatus ReasonCode;
  %let nums=;
  %let expected=1;
%end;
%else %if &role=working_target %then %do;
  %let chars=;
  %let nums=Tau2 Sigma2 Alpha ComponentCount RIComponents ResidualComponents;
  %let expected=1;
%end;
%else %if &role=levels %then %do;
  %let chars=TargetID TargetRole NumericStatus PAdjustment CIAdjustment FamilyID;
  %let nums=TargetIndex TargetKind GridID CategoryIndexA CategoryIndexB TimeFromTransfusion CategoryCodeA CategoryCodeB ContrastStatus Estimate StdErr DF tValue Probt Lower Upper Variance ReferenceVariance BaselineMinute EndpointMinute;
  %let expected=%eval(1441*&k);
%end;
%else %if &role=changes %then %do;
  %let chars=TargetID TargetRole NumericStatus PAdjustment CIAdjustment FamilyID;
  %let nums=TargetIndex TargetKind GridID CategoryIndexA CategoryIndexB TimeFromTransfusion CategoryCodeA CategoryCodeB ContrastStatus Estimate StdErr DF tValue Probt Lower Upper Variance ReferenceVariance BaselineMinute EndpointMinute;
  %let expected=%eval(1441*&k);
%end;
%else %if &role=within %then %do;
  %let chars=TargetID TargetRole NumericStatus PAdjustment CIAdjustment FamilyID;
  %let nums=TargetIndex TargetKind GridID CategoryIndexA CategoryIndexB TimeFromTransfusion CategoryCodeA CategoryCodeB ContrastStatus Estimate StdErr DF tValue Probt Lower Upper Variance ReferenceVariance BaselineMinute EndpointMinute;
  %let expected=&k;
%end;
%else %if &role=pairwise %then %do;
  %let chars=TargetID TargetRole NumericStatus PAdjustment CIAdjustment FamilyID;
  %let nums=TargetIndex TargetKind GridID CategoryIndexA CategoryIndexB TimeFromTransfusion CategoryCodeA CategoryCodeB ContrastStatus Estimate StdErr DF tValue Probt Lower Upper Variance ReferenceVariance BaselineMinute EndpointMinute Rank PValue PValue_Holm;
  %let expected=%eval(&k*(&k-1)/2);
%end;
%else %if &role=joint %then %do;
  %let chars=TestRole NumericStatus;
  %let nums=TestIndex JointStatus Q Nu DF1 DF2 Wald FValue ProbF MomentDenominator;
  %let expected=2;
%end;
%else %if &role=cat_availability %then %do;
  %let chars=AvailabilityReason;
  %let nums=CategoryCode CategoryIndex Available;
  %let expected=&planned;
%end;
%else %if &role=contrast_plan %then %do;
  %let chars=ContrastID ContrastType ExclusionReason FamilyID;
  %let nums=CategoryCodeA CategoryCodeB CategoryIndexA CategoryIndexB Planned Active BeforeMinute AfterMinute;
  %let expected=%eval(&planned+&planned*(&planned-1)/2);
%end;
%else %if &role=family_plan %then %do;
  %let chars=FamilyID FamilyRole FactorName Model VitalCode PAdjustment CIAdjustment FreezeStage;
  %let nums=PlannedCategories AvailableCategories PlannedPairs ActivePairs PlanVersion;
  %let expected=1;
%end;
%else %if &role=si_covariance %then %do;
  %let chars=;
  %let nums=Row Col Value;
  %let expected=%eval(&p*&p);
%end;
%else %if &role=si_basis %then %do;
  %let chars=;
  %let nums=Parameter ActiveColumn Value;
  %let expected=%eval(&p*&rank);
%end;
%else %if &role=si_bread %then %do;
  %let chars=;
  %let nums=Row Col Value;
  %let expected=%eval(&rank*&rank);
%end;
%else %if &role=si_moment %then %do;
  %let chars=;
  %let nums=&mvars;
  %let expected=&dim;
%end;
%else %if &role=si_spanbasis %then %do;
  %let chars=;
  %let nums=&pvars;
  %let expected=&h;
%end;
%else %if &role=si_spanrobust %then %do;
  %let chars=;
  %let nums=&hvars;
  %let expected=&h;
%end;
%else %if &role=si_solution %then %do;
  %let chars=;
  %let nums=Parameter Estimate;
  %let expected=&p;
%end;
%else %if &role=si_context %then %do;
  %let chars=StatisticKind;
  %let nums=Tau2 Sigma2 Alpha DesignRank ParameterCount ClusterCount SpanDimension MomentDimension RoundoffEnvelope CertifiedClusters MaxCertifiedNullity;
  %let expected=1;
%end;
%else %if &role=target_keys %then %do;
  %let chars=;
  %let nums=TargetIndex TargetKind GridID CategoryIndexA CategoryIndexB TimeFromTransfusion CategoryCodeA CategoryCodeB;
  %let expected=%eval(2*1441*&k+&k+&k*(&k-1)/2);
%end;
%else %if &role=target_design %then %do;
  %let chars=;
  %let nums=TargetIndex &xvars;
  %let expected=%eval(2*1441*&k+&k+&k*(&k-1)/2);
%end;
%else %if &role=joint_design %then %do;
  %let chars=;
  %let nums=TestIndex ConstraintIndex CategoryIndex AnchorIndex &xvars;
  %let expected=%eval(7*(&k-1));
%end;
%else %if &role=si_moment_error %then %do;
  %let chars=;
  %let nums=&mvars;
  %let expected=&dim;
%end;
%else %if &role=si_scalar_weights %then %do;
  %let chars=;
  %let nums=TargetIndex &hvars;
  %let expected=%eval(2*1441*&k+&k+&k*(&k-1)/2);
%end;
%else %if &role=si_scalar_certificate %then %do;
  %let chars=;
  %let nums=TargetIndex Denominator AbsError RelativeErrorUpper IdealRelativeErrorUpper Resolved;
  %let expected=%eval(2*1441*&k+&k+&k*(&k-1)/2);
%end;
%else %if &role=joint_weights %then %do;
  %let chars=;
  %let nums=TestIndex ConstraintIndex &hvars;
  %let expected=%eval(7*(&k-1));
%end;
%else %if &role=joint_certificate %then %do;
  %let chars=;
  %let nums=TestIndex Denominator AbsError RelativeErrorUpper IdealRelativeErrorUpper Resolved NuLower NuUpper DF2Lower DF2Upper DF2Sign;
  %let expected=%eval(2*(&k>1));
%end;
%else %if &role=certificate_context %then %do;
  %let chars=CertificateProtocol CertificateMethod CertificateScope ConstructionSourceSHA256 HostProbe WeightProvenance NumericTransport;
  %let nums=CertificateVersion SpanDimension MomentDimension;
  %let expected=1;
%end;
%else %if &role=scalar_unavailable %then %do;

  %let chars=TargetID TargetRole UnavailableReason;
  %let nums=TargetIndex TargetKind GridID NativeContrastStatus Denominator AbsError RelativeErrorUpper IdealRelativeErrorUpper Resolved;
  %let expected=&nunavail;
%end;
%mend;
%macro rbc_export_cr2_white_archive(outlib=,prefix=,exportlib=,scalar_policy=STRICT);
%local context_chars context_nums context roles role chars nums expected fields dsid rc
        p rank h dim k planned bad n i j field member path prior_decimal xvars pvars hvars mvars
        nroles ncols row1 row2 row3 row4 row5 row6 row7 row8 row9 row10 row11 row12 row13 row14
        row15 row16 row17 row18 row19 row20 row21 row22 col1 col2 col3 col4 col5 col6 col7 col8
        col9 col10 col11 col12 col13 col14 col15 col16 col17 col18 col19 col20 col21 col22 row23 row24 row25 row26 row27 row28 col23 col24 col25 col26 col27 col28
        row29 col29 lcu cr2protocol nunavail nl nc;
%global RBC_CR2_EXPORT_OK RBC_CR2_EXPORT_REASON RBC_ARCHIVE_REASON;
%let RBC_CR2_EXPORT_OK=0; %let RBC_CR2_EXPORT_REASON=NOT_COMPLETED; %let nunavail=0;
%if not %sysmacexist(rbc_archive_schema) %then %do;
 %rbc_cr2_export_reject(reason=ARCHIVE_SCHEMA_MODULE_REQUIRED); %return;
%end;
 %if not %sysmacexist(rbc_export_exact_csv) %then %do;
  %rbc_cr2_export_reject(reason=EXACT_EXPORT_MODULE_REQUIRED); %return;
 %end;
%if %superq(scalar_policy)=STRICT %then %do;
  %let lcu=0; %let cr2protocol=RBC_CR2_GLS_WHITE_MODEL_V2;
%end;
%else %if %superq(scalar_policy)=LEVEL_CHANGE_PRECISION_UNAVAILABLE_V1 %then %do;
  %let lcu=1; %let cr2protocol=RBC_CR2_GLS_WHITE_MODEL_V2_LCPU_V1;
%end;
%else %do;
  %rbc_cr2_export_reject(reason=SCALAR_POLICY_INVALID); %return;
%end;
%if %length(%superq(prefix))<1 or %length(%superq(prefix))>9 or
    %length(%superq(outlib))<1 or %length(%superq(outlib))>8 or
    %length(%superq(exportlib))<1 or %length(%superq(exportlib))>8 %then %do;
  %rbc_cr2_export_reject(reason=INVALID_NAMES); %return;
%end;
%if not %sysfunc(nvalid(&prefix,V7)) or not %sysfunc(nvalid(&outlib,V7)) or
    not %sysfunc(nvalid(&exportlib,V7)) or %sysfunc(libref(&outlib)) ne 0 or
    %sysfunc(libref(&exportlib)) ne 0 %then %do;
  %rbc_cr2_export_reject(reason=INVALID_LIBRARIES); %return;
%end;
%if %sysfunc(fileref(_rbc2ex))<=0 or %sysfunc(exist(work._rbc2_stage,DATA)) or
    %sysfunc(exist(work._rbc2_stage,VIEW)) or %sysfunc(exist(work._rbc2_manifest,DATA)) or
    %sysfunc(exist(work._rbc2_manifest,VIEW)) %then %do;
  %rbc_cr2_export_reject(reason=EXPORT_SCRATCH_COLLISION); %return;
%end;
%let context_chars=RunId AnalysisSpecId CohortMode PopulationId FitId InputSnapshotId CodeHash ConfigHash DesignId ProfileId DFMethod JobID SubjectKeySource SubjectAlias DesignIdentityKind ProfileIdentityKind InferenceStatus WorkingDFMethod WorkingInferenceStatus Scope CovarianceMethod ScalarDFMethod JointDFMethod WorkingTarget CR2Protocol CR2ArchiveID CalibrationDomain StructuralCertificate;
%let context_nums=BindingVersion WorkingBindingVersion TargetCalibrationVerified AllCoefficientsCalibrated;
%let context=&context_chars &context_nums;
%let roles=identity status working_target si_context family_plan certificate_context;
%do i=1 %to 6;
  %let role=%scan(&roles,&i);
  %if not %sysfunc(exist(&outlib..&prefix._&role,DATA)) or
      %sysfunc(exist(&outlib..&prefix._&role,VIEW)) %then %do;
    %rbc_cr2_export_reject(reason=SOURCE_DATA_MEMBER_REQUIRED); %return;
  %end;
%end;
%let RBC_ARCHIVE_REASON=;
%rbc_archive_schema(data=&outlib..&prefix._identity,chars=&context_chars,nums=&context_nums);
%rbc_archive_schema(data=&outlib..&prefix._si_context,chars=&context_chars StatisticKind,
  nums=&context_nums ParameterCount DesignRank SpanDimension MomentDimension);
%rbc_archive_schema(data=&outlib..&prefix._family_plan,chars=&context_chars,nums=&context_nums PlannedCategories AvailableCategories);
%rbc_archive_schema(data=&outlib..&prefix._status,chars=&context_chars IntegrationStatus ReasonCode,nums=&context_nums);
%rbc_archive_schema(data=&outlib..&prefix._certificate_context,chars=&context_chars CertificateProtocol CertificateMethod CertificateScope ConstructionSourceSHA256 HostProbe WeightProvenance NumericTransport,
 nums=&context_nums CertificateVersion SpanDimension MomentDimension);
%if %length(&RBC_ARCHIVE_REASON)>0 %then %do;
  %rbc_cr2_export_reject(reason=INPUT_SCHEMA_INVALID); %return;
%end;
%let bad=0; %let n=0;
data _null_;
 set &outlib..&prefix._identity end=last;
 if _n_ ne 1 or cmiss(of &context_chars)>0 or BindingVersion ne 3 or WorkingBindingVersion ne 1
    or InferenceStatus ne 'CR2_CHECKS_PASSED' or WorkingInferenceStatus ne 'MODEL_BASED_CANDIDATE'
    or WorkingDFMethod ne 'RESIDUAL' or DFMethod ne 'SATTERTHWAITE'
    or CalibrationDomain ne 'FIXED_PREDECLARED_TARGET_SPAN' or StructuralCertificate ne 'RAW_LITERAL_SUPPORT_V1'
    or TargetCalibrationVerified ne 1 or AllCoefficientsCalibrated ne 0
    or CovarianceMethod ne 'GLS_WHITENED_CR2' or ScalarDFMethod ne 'CONTRAST_SATTERTHWAITE'
    or JointDFMethod ne 'HTZ' or WorkingTarget ne 'FROZEN_REML_RANDOM_INTERCEPT_IID'
    or CR2Protocol ne "&cr2protocol" or CR2ArchiveID ne "&prefix"
    or not ((Scope='SYNTHETIC_DATA_ONLY' and CohortMode='synthetic') or
       (Scope='LOCAL_SAMPLE_MODEL_INFERENCE' and CohortMode='development_sample') or
       (Scope='FULL_COHORT_MODEL_INFERENCE' and CohortMode='full_cohort'))
    or not prxmatch('/^[0-9a-fA-F]{32}$/',strip(RunId))
    or not prxmatch('/^[0-9a-fA-F]{64}$/',strip(CodeHash))
    or not prxmatch('/^[0-9a-fA-F]{64}$/',strip(ConfigHash)) then call symputx('bad',1,'L');
 if last then call symputx('n',_n_,'L');
run;
%if &bad ne 0 or &n ne 1 %then %do; %rbc_cr2_export_reject(reason=IDENTITY_INVALID); %return; %end;
%let n=0;
data _null_;
 set &outlib..&prefix._status end=last;
 if _n_ ne 1 or IntegrationStatus ne 'CR2_CHECKS_PASSED' or ReasonCode ne 'PASS' then call symputx('bad',1,'L');
 if last then call symputx('n',_n_,'L');
run;
%if &bad ne 0 or &n ne 1 %then %do; %rbc_cr2_export_reject(reason=INTEGRATION_NOT_COMPLETE); %return; %end;
%let n=0;
data _null_;
 set &outlib..&prefix._si_context end=last;
 if _n_ ne 1 or nmiss(ParameterCount,DesignRank,SpanDimension,MomentDimension)>0 or
    ParameterCount ne int(ParameterCount) or DesignRank ne int(DesignRank) or SpanDimension ne int(SpanDimension)
    or SpanDimension<1 or DesignRank<SpanDimension or ParameterCount<DesignRank or ParameterCount>500 or
    MomentDimension ne SpanDimension*(SpanDimension+1)/2 or StatisticKind ne 'AUGMENTED_QR'
    or 8*(4*MomentDimension*(DesignRank*(DesignRank+1)/2)+6*MomentDimension*MomentDimension)>512*2**20
    or 8*(12*MomentDimension*(DesignRank*(DesignRank+1)/2)+32*MomentDimension*MomentDimension)+64*2**20>2048*2**20
    then call symputx('bad',1,'L');
 call symputx('p',ParameterCount,'L'); call symputx('rank',DesignRank,'L');
 call symputx('h',SpanDimension,'L'); call symputx('dim',MomentDimension,'L');
 if last then call symputx('n',_n_,'L');
run;
%if &bad ne 0 or &n ne 1 %then %do; %rbc_cr2_export_reject(reason=DIMENSIONS_INVALID); %return; %end;
%let n=0;
data _null_;
 set &outlib..&prefix._family_plan end=last;
 if _n_ ne 1 or nmiss(PlannedCategories,AvailableCategories)>0 or
    PlannedCategories ne int(PlannedCategories) or AvailableCategories ne int(AvailableCategories) or
    PlannedCategories<1 or PlannedCategories>7 or AvailableCategories<1 or AvailableCategories>PlannedCategories
    then call symputx('bad',1,'L');
 call symputx('k',AvailableCategories,'L'); call symputx('planned',PlannedCategories,'L');
 if last then call symputx('n',_n_,'L');
run;
%if &bad ne 0 or &n ne 1 or &syscc>4 or &syserr>4 %then %do;
 %rbc_cr2_export_reject(reason=FAMILY_OR_PREFLIGHT_INVALID); %return;
%end;
 
%let n=0;
data _null_;
 set &outlib..&prefix._certificate_context end=last;
 if _n_ ne 1 or CertificateProtocol ne 'RBC_MOMENT_CERTIFICATE_ARCHIVE_V1'
    or CertificateMethod ne 'ENTRYWISE_COMPUTED_GEOMETRY_V1'
    or CertificateScope ne 'COMPUTED_H_L_AND_NATIVE_SCORING_WEIGHT_CONTRACTION_ONLY'
    or not prxmatch('/^[0-9a-f]{64}$/',strip(ConstructionSourceSHA256))
    or HostProbe ne 'PASS' or WeightProvenance ne 'NATIVE_BINARY64'
    or NumericTransport ne 'HEX16_IEEE754' or CertificateVersion ne 1
    or SpanDimension ne &h or MomentDimension ne &dim then call symputx('bad',1,'L');
 if last then call symputx('n',_n_,'L');
run;
%if &bad ne 0 or &n ne 1 or &syscc>4 or &syserr>4 %then %do;
 %rbc_cr2_export_reject(reason=CERTIFICATE_CONTEXT_INVALID); %return;
%end;
%let xvars=; %let pvars=; %let hvars=; %let mvars=;
%do j=1 %to &p; %let xvars=&xvars RBCX&j; %let pvars=&pvars COL&j; %end;
%do j=1 %to &h; %let hvars=&hvars COL&j; %end;
%do j=1 %to &dim; %let mvars=&mvars COL&j; %end;
%let roles=identity status working_target levels changes within pairwise joint cat_availability contrast_plan family_plan si_covariance si_basis si_bread si_moment si_spanbasis si_spanrobust si_solution si_context target_keys target_design si_moment_error si_scalar_weights si_scalar_certificate joint_weights joint_certificate certificate_context;
%if &k>1 %then %let roles=&roles joint_design;
%if &lcu=1 %then %do;
  %let nl=-1; %let nc=-1;
  proc sql noprint;
    select count(*) into :nl trimmed from &outlib..&prefix._levels where NumericStatus='MOMENT_PRECISION_UNRESOLVED';
    select count(*) into :nc trimmed from &outlib..&prefix._changes where NumericStatus='MOMENT_PRECISION_UNRESOLVED';
  quit;
  %if &nl<0 or &nc<0 or &syscc>4 or &syserr>4 %then %do;
    %rbc_cr2_export_reject(reason=UNAVAILABLE_SET_INVALID); %return;
  %end;
  %let nunavail=%eval(&nl+&nc);
  %let roles=&roles scalar_unavailable;
%end;
%let nroles=%sysfunc(countw(&roles));
%do i=1 %to &nroles;
 %let role=%scan(&roles,&i); %rbc_cr2_white_role_fields(role=&role);
 %if not %sysfunc(exist(&outlib..&prefix._&role,DATA)) or %sysfunc(exist(&outlib..&prefix._&role,VIEW)) %then %do;
   %rbc_cr2_export_reject(reason=SOURCE_DATA_MEMBER_REQUIRED); %return;
 %end;
 %let RBC_ARCHIVE_REASON=;
 %rbc_archive_schema(data=&outlib..&prefix._&role,chars=&context_chars &chars,nums=&context_nums &nums);
 %if %length(&RBC_ARCHIVE_REASON)>0 %then %do; %rbc_cr2_export_reject(reason=INPUT_SCHEMA_INVALID); %return; %end;
 %let dsid=%sysfunc(open(&outlib..&prefix._&role,i));
 %let n=%sysfunc(attrn(&dsid,nlobs)); %let rc=%sysfunc(close(&dsid));
 %if &n ne &expected %then %do; %rbc_cr2_export_reject(reason=ROW_CARDINALITY_INVALID); %return; %end;
 %let row&i=&n; %let col&i=%sysfunc(countw(&context &chars &nums));
 data _null_;
  if _n_=1 then set &outlib..&prefix._identity(keep=&context rename=(
   %do j=1 %to %sysfunc(countw(&context)); %let field=%scan(&context,&j); &field=_C2_&field %end;
  ));
  set &outlib..&prefix._&role(keep=&context);
  %do j=1 %to %sysfunc(countw(&context)); %let field=%scan(&context,&j);
   if &field ne _C2_&field then call symputx('bad',1,'L');
  %end;
 run;
 %if &bad ne 0 or &syscc>4 or &syserr>4 %then %do; %rbc_cr2_export_reject(reason=CONTEXT_MISMATCH); %return; %end;
%end;
%let path=%qsysfunc(pathname(&exportlib));
data _null_;
 %do i=1 %to %eval(&nroles+1);
  %let role=archive_manifest; %if &i<=&nroles %then %let role=%scan(&roles,&i);
  rc=filename('_rbc2ex',cats(pathname("&exportlib"),'/',"&prefix._&role..csv"));
  if rc ne 0 or fexist('_rbc2ex') then call symputx('bad',1,'L'); rc=filename('_rbc2ex');
 %end;
run;
%if &bad ne 0 or &syscc>4 or &syserr>4 %then %do; %rbc_cr2_export_reject(reason=EXPORT_TARGET_NOT_FRESH); %return; %end;
%let prior_decimal=%sysfunc(getoption(decimalconv,keyword));
options decimalconv=stdieee;
%do i=1 %to &nroles;
 %let role=%scan(&roles,&i); %rbc_cr2_white_role_fields(role=&role);
 data work._rbc2_stage;
  retain &context &chars &nums;
  set &outlib..&prefix._&role(keep=&context &chars &nums);
  format _numeric_ e32.; format _character_;
 run;
 data _null_;
  rc=filename('_rbc2ex',cats(pathname("&exportlib"),'/',"&prefix._&role..csv"));
  if rc ne 0 or fexist('_rbc2ex') then call symputx('bad',1,'L'); rc=filename('_rbc2ex');
 run;
 %if &bad ne 0 or &syscc>4 or &syserr>4 %then %goto export_failed;
 filename _rbc2ex "%superq(path)/&prefix._&role..csv" encoding='utf-8' lrecl=1048576;
 %rbc_export_exact_csv(data=work._rbc2_stage,fileref=_rbc2ex);
 %if &RBC_EXACT_CSV_OK ne 1 %then %goto export_failed;
 filename _rbc2ex clear;
 %if &syscc>4 or &syserr>4 %then %goto export_failed;
%end;
data work._rbc2_manifest;
 retain &context;
 if _n_=1 then set &outlib..&prefix._identity(keep=&context);
 length Protocol $32 Role $32 FileName $80 NumericFormat $16 TextEncoding $8 ExportStatus $24;
 Protocol='RBC_CR2_GLS_WHITE_ARCHIVE_V2'; NumericFormat='HEX16_IEEE754'; TextEncoding='UTF-8'; ExportStatus='EXPORTED_LOCAL_ONLY';
 %do i=1 %to &nroles;
  %let role=%scan(&roles,&i); Role="&role"; FileName="&prefix._&role..csv";
  RowCount=&&row&i; ColumnCount=&&col&i; output;
 %end;
 stop; format _numeric_ e32.;
run;
data _null_;
 rc=filename('_rbc2ex',cats(pathname("&exportlib"),'/',"&prefix._archive_manifest.csv"));
 if rc ne 0 or fexist('_rbc2ex') then call symputx('bad',1,'L'); rc=filename('_rbc2ex');
run;
%if &bad ne 0 or &syscc>4 or &syserr>4 %then %goto export_failed;
filename _rbc2ex "%superq(path)/&prefix._archive_manifest.csv" encoding='utf-8' lrecl=1048576;
%rbc_export_exact_csv(data=work._rbc2_manifest,fileref=_rbc2ex);
%if &RBC_EXACT_CSV_OK ne 1 %then %goto export_failed;
filename _rbc2ex clear;
%if &syscc>4 or &syserr>4 %then %goto export_failed;
options &prior_decimal;
proc datasets library=work nolist; delete _rbc2_stage _rbc2_manifest; quit;
%if &syscc>4 or &syserr>4 %then %do; %rbc_cr2_export_reject(reason=EXPORT_CLEANUP_FAILED); %return; %end;
%let RBC_CR2_EXPORT_OK=1; %let RBC_CR2_EXPORT_REASON=EXPORTED_LOCAL_ONLY;
%return;
%export_failed:
 filename _rbc2ex clear;
 proc datasets library=work nolist; delete _rbc2_stage _rbc2_manifest; quit;
options &prior_decimal;
%rbc_cr2_export_reject(reason=EXPORT_WRITE_FAILED);
%mend;

%macro rbc_report_export_reject(reason=);
 %global RBC_REPORT_EXPORT_OK RBC_REPORT_EXPORT_REASON;
 %let RBC_REPORT_EXPORT_OK=0; %let RBC_REPORT_EXPORT_REASON=&reason;
 %put NOTE: RBC_REPORT_EXPORT_REJECT &reason;
%mend;
%macro rge_schema(data=,chars=,nums=);
 %local h i v j rc;
 %if not %sysfunc(exist(&data,DATA)) or %sysfunc(exist(&data,VIEW)) %then %do;
   %rbc_report_export_reject(reason=SOURCE_DATA_REQUIRED); %return;
 %end;
 %let h=%sysfunc(open(&data,i));
 %if &h=0 %then %do; %rbc_report_export_reject(reason=SOURCE_METADATA_UNAVAILABLE); %return; %end;
 %do i=1 %to %sysfunc(countw(%str( )&chars));
  %let v=%scan(&chars,&i); %let j=%sysfunc(varnum(&h,&v));
  %if &j=0 %then %rbc_report_export_reject(reason=SOURCE_SCHEMA_INVALID);
  %else %if %sysfunc(vartype(&h,&j)) ne C %then %rbc_report_export_reject(reason=SOURCE_SCHEMA_INVALID);
 %end;
 %do i=1 %to %sysfunc(countw(%str( )&nums));
  %let v=%scan(&nums,&i); %let j=%sysfunc(varnum(&h,&v));
  %if &j=0 %then %rbc_report_export_reject(reason=SOURCE_SCHEMA_INVALID);
  %else %if %sysfunc(vartype(&h,&j)) ne N %then %rbc_report_export_reject(reason=SOURCE_SCHEMA_INVALID);
 %end;
 %let rc=%sysfunc(close(&h));
%mend;
%macro rge_fields;
 %let chars=; %let nums=; %let sourcechars=; %let source=; %let expected=-1;
%if &role=pipeline_identity %then %do;
%let chars=CoverageStatus UnitStatus ExecutionStatus AgeBandDefinition SourceYearBoundsMeaning;
%let sourcechars=CoverageStatus UnitStatus ExecutionStatus AgeBandDefinition SourceYearBoundsMeaning;
%let nums=SourceExtractFirstYear SourceExtractLastYear;
%let expected=1;
%let source=prepared;
%end;
%else %if &role=source_flow %then %do;
%let chars=Stage CountingUnit DataScope;
%let sourcechars=Stage CountingUnit DataScope;
%let nums=Count;
%let expected=10;
%let source=prepared;
%end;
%else %if &role=flow_metrics %then %do;
%let chars=FlowProtocol MetricID Stage CountingUnit Overlap DenominatorID DataScope;
%let sourcechars=&chars;
%let nums=Count;
%let expected=343;
%let source=prepared;
%end;
%else %if &role=flow_checks %then %do;
%let chars=FlowProtocol Check Status DataScope;
%let sourcechars=&chars;
%let nums=;
%let expected=3;
%let source=prepared;
%end;
%else %if &role=source_exclusions %then %do;
%let chars=Stage CountingUnit ReasonCode DataScope;
%let sourcechars=Stage CountingUnit ReasonCode DataScope;
%let nums=Count;
%let expected=-1;
%let source=prepared;
%end;
%else %if &role=prepare_manifest %then %do;
%let chars=MappingEvidence ModelGroupingEvidence AdmissionPolicy ConcurrentPolicy UnitKeyDefinition PriorUnitDefinition IndexHistoryDefinition LedgerCoverage MedicationEncoding NativeOutcomeUnits ScientificFreeze DonationDateUnit RuleApproval MeasurementReconciliation MedicationReconciliation MedicationNormalizationRule AdmissionTimeDateStyle DataScope;
%let sourcechars=MappingEvidence ModelGroupingEvidence AdmissionPolicy ConcurrentPolicy UnitKeyDefinition PriorUnitDefinition IndexHistoryDefinition LedgerCoverage MedicationEncoding NativeOutcomeUnits ScientificFreeze DonationDateUnit RuleApproval MeasurementReconciliation MedicationReconciliation MedicationNormalizationRule AdmissionTimeDateStyle DataScope;
%let nums=NormalizationMeasurementCount NormalizationFieldCount Normalized_Crystalloid_1 Normalized_Crystalloid_24 Normalized_Pressors_1 Normalized_Pressors_24 Normalized_Sedatives_1 Normalized_Sedatives_24 NormalizationRelativeBound OriginalDistinctPayloadRows;
%let expected=1;
%let source=prepared;
%end;
%else %if &role=prepare_status %then %do;
%let chars=Predicate Status DataScope;
%let sourcechars=Predicate Status DataScope;
%let nums=;
%let expected=16;
%let source=prepared;
%end;
%else %if &role=population_counts %then %do;
%let chars=ReportedPopulationId PopulationStatus CoverageScope CoverageEndBoundary FollowupDefinition;
%let sourcechars=PopulationId PopulationStatus CoverageScope CoverageEndBoundary FollowupDefinition;
%let nums=NEvents NPersons;
%let expected=3;
%let source=prepared;
%end;
%else %if &role=followup_counts %then %do;
%let chars=FollowupStatus CoverageScope CoverageEndBoundary FollowupDefinition;
%let sourcechars=FollowupStatus CoverageScope CoverageEndBoundary FollowupDefinition;
%let nums=NEvents NPersons;
%let expected=-1;
%let source=prepared;
%end;
%else %if &role=report_identity %then %do;
%let chars=ReportStatus;
%let sourcechars=ReportStatus;
%let nums=;
%let expected=1;
%let source=report;
%end;
%else %if &role=report_status %then %do;
%let chars=Status;
%let sourcechars=Status;
%let nums=;
%let expected=1;
%let source=report;
%end;
%else %if &role=report_unavailable %then %do;
%let chars=Item AvailabilityStatus ReasonCode;
%let sourcechars=Item AvailabilityStatus ReasonCode;
%let nums=;
%let expected=2;
%let source=generated;
%end;
%else %if &role=rdd_cohort_counts %then %do;
%let chars=CountingUnit CountDefinition;
%let sourcechars=CountingUnit CountDefinition;
%let nums=Count;
%let expected=4;
%let source=report;
%end;
%else %if &role=rdd_patient_sex %then %do;
%let chars=Patient_Sex DenominatorDefinition DenominatorScope;
%let sourcechars=Patient_Sex DenominatorDefinition DenominatorScope;
%let nums=No_of_Patients Denominator Percent;
%let expected=-1;
%let source=report;
%end;
%else %if &role=rdd_patient_age %then %do;
%let chars=DenominatorDefinition DenominatorScope;
%let sourcechars=DenominatorDefinition DenominatorScope;
%let nums=N_Age N_Missing_Age Mean_Age SD_Age Median_Age Q1_Age Q3_Age Min_Age Max_Age NPersons Denominator;
%let expected=1;
%let source=report;
%end;
%else %if &role=rdd_patient_age_groups %then %do;
%let chars=BandCode BandLabel DenominatorDefinition DenominatorScope;
%let sourcechars=BandCode BandLabel DenominatorDefinition DenominatorScope;
%let nums=BandOrder Count Denominator Percent;
%let expected=9;
%let source=report;
%end;
%else %if &role=rdd_patient_ward %then %do;
%let chars=WardCode Status DenominatorDefinition DenominatorScope;
%let sourcechars=WardCode Status DenominatorDefinition DenominatorScope;
%let nums=No_of_Patients Denominator;
%let expected=-1;
%let source=report;
%end;
%else %if &role=rdd_patient_saps %then %do;
%let chars=Status DenominatorDefinition DenominatorScope;
%let sourcechars=Status DenominatorDefinition DenominatorScope;
%let nums=NAvailable Mean SD Median Q1 Q3 NPersons NMissing NInvalid NNotRequested Denominator;
%let expected=1;
%let source=report;
%end;
%else %if &role=rdd_unit_categories %then %do;
%let chars=Factor CategoryCode CategoryLabel Status DenominatorDefinition;
%let sourcechars=Factor CategoryCode CategoryLabel Status DenominatorDefinition;
%let nums=Eligible No_of_Transfused_Units NTotalUnits NEligibleUnits NValid NMissing NInvalid NExcluded Percent;
%let expected=-1;
%let source=report;
%end;
%else %if &role=rdd_units_per_person %then %do;
%let chars=UnitScope CountDefinition DenominatorDefinition DenominatorScope;
%let sourcechars=UnitScope CountDefinition DenominatorDefinition DenominatorScope;
%let nums=Linked_Index_Units No_of_Patients Denominator Relative_Frequency;
%let expected=-1;
%let source=report;
%end;
%else %if &role=rdd_anchor_audit %then %do;
%let chars=DenominatorDefinition DenominatorScope;
%let sourcechars=DenominatorDefinition DenominatorScope;
%let nums=NPersons PersonsWithChangingAge PersonsWithChangingSex PersonsWithEquivalentFirstTies Denominator;
%let expected=1;
%let source=report;
%end;
%else %if &role=rdd_manifest %then %do;
%let chars=AnchorPolicy TiePolicy UnitScope AgeRangePolicy SAPSOption DescriptorStatus;
%let sourcechars=AnchorPolicy TiePolicy UnitScope AgeRangePolicy SAPSOption DescriptorStatus;
%let nums=;
%let expected=1;
%let source=report;
%end;
%else %if &role=qa_outcome_counts %then %do;
%let chars=VitalCode Outcome SourcePopulationId AnalysisPopulationId;
%let sourcechars=VitalCode Outcome SourcePopulationId AnalysisPopulationId;
%let nums=OutcomeOrder NRows NPatients NEvents NPatientsWithValue NEventsWithValue NMissingValue NMissingPersonKey NMissingEventKey NMissingDatetime NMissingTransDt NNegativeValueFlag NOxygenAbove100Flag NNegativeICUTimeFlag NNegativeRBCCountFlag NNonintegerRBCCountFlag NNegativeCrystalloid1Flag NNegativeCrystalloid24Flag NNegativePressors1Flag NNegativePressors24Flag NNegativeSedatives1Flag NNegativeSedatives24Flag NRowsMissingBaseCovariate NRowsMissingFullCovariate;
%let expected=7;
%let source=report;
%end;
%else %if &role=qa_covariate_missing %then %do;
%let chars=VitalCode Outcome Variable MissingDefinition SourcePopulationId AnalysisPopulationId;
%let sourcechars=VitalCode Outcome Variable MissingDefinition SourcePopulationId AnalysisPopulationId;
%let nums=OutcomeOrder NRows NMissing NNonmissing;
%let expected=84;
%let source=report;
%end;
%else %if &role=qa_value_quantiles %then %do;
%let chars=VitalCode Outcome QuantileMethod ValuePopulation SourcePopulationId AnalysisPopulationId;
%let sourcechars=VitalCode Outcome QuantileMethod ValuePopulation SourcePopulationId AnalysisPopulationId;
%let nums=OutcomeOrder NValues ValueP5 ValueP25 ValueP50 ValueP75 ValueP95;
%let expected=7;
%let source=report;
%end;
%else %if &role=qa_record_intervals %then %do;
%let chars=VitalCode Outcome CoverageStatus DefinitionId SourceGroup GroupingDefinition QuantilePopulation SourcePopulationId AnalysisPopulationId;
%let sourcechars=VitalCode Outcome CoverageStatus DefinitionId SourceGroup GroupingDefinition QuantilePopulation SourcePopulationId AnalysisPopulationId;
%let nums=OutcomeOrder NUniqueMeasurements NUniqueTimestamps NIntervals NNonpositiveIntervals NSeriesStarts NMissingDatetime NTimestampTieGroups NRecordsAtTiedTimestamps IntervalP5Seconds Q1IntervalSeconds MedianIntervalSeconds Q3IntervalSeconds IntervalP95Seconds;
%let expected=7;
%let source=report;
%end;
%else %if &role=qa_duplicate_records %then %do;
%let chars=VitalCode Outcome DuplicateKeyDefinition ActionTaken SourcePopulationId AnalysisPopulationId;
%let sourcechars=VitalCode Outcome DuplicateKeyDefinition ActionTaken SourcePopulationId AnalysisPopulationId;
%let nums=OutcomeOrder NDuplicateGroups NRowsInDuplicateGroups NExtraDuplicateRows NMissingDuplicateKeyRows;
%let expected=7;
%let source=report;
%end;
%else %if &role=qa_processing_status %then %do;
%let chars=Field Status Interpretation ActionTaken SourcePopulationId AnalysisPopulationId;
%let sourcechars=Field Status Interpretation ActionTaken SourcePopulationId AnalysisPopulationId;
%let nums=;
%let expected=11;
%let source=report;
%end;
%else %if &role=qa_source_value_quantiles %then %do;
%let chars=VitalCode Outcome CoverageStatus QuantileMethod ValuePopulation SourcePopulationId AnalysisPopulationId;
%let sourcechars=VitalCode Outcome CoverageStatus QuantileMethod ValuePopulation SourcePopulationId AnalysisPopulationId;
%let nums=OutcomeOrder NValues ValueP5 ValueP25 ValueP50 ValueP75 ValueP95;
%let expected=7;
%let source=report;
%end;
%else %if &role=observed_data_summary %then %do;
%let chars=VitalCode Outcome Factor CategoryLabel Abbreviation FactorName FactorCategory InferenceMethod DenominatorDefinition Status InferenceStatus Pre_InferenceStatus Post_InferenceStatus InferenceApprovalStatus;
%let sourcechars=VitalCode Outcome Factor CategoryLabel Abbreviation FactorName FactorCategory InferenceMethod DenominatorDefinition Status InferenceStatus Pre_InferenceStatus Post_InferenceStatus InferenceApprovalStatus;
%let nums=OutcomeOrder CategoryCode NEligibleEvents NEligiblePatients NPreAvailableEvents NPostAvailableEvents NDiff NPairedPatients NPreOnlyEvents NPostOnlyEvents NNeitherAvailableEvents NPreWindowRecords NPostWindowRecords NPairedPreValues NPairedPostValues Pre_Mean Pre_SD Post_Mean Post_SD Diff_Mean Diff_SD WindowHalfWidthMinutes Diff_SE Diff_LCL Diff_UCL DF PValue Pre_SE Pre_DF Pre_LCL Pre_UCL Post_SE Post_DF Post_LCL Post_UCL FitPersons FitEvents FitCategories ScoreIdentityNorm;
%let expected=7;
%let source=report;
%end;
%else %if &role=factor_observed_data_summary %then %do;
%let chars=VitalCode Outcome Factor CategoryLabel Abbreviation FactorName FactorCategory InferenceMethod DenominatorDefinition Status InferenceStatus Pre_InferenceStatus Post_InferenceStatus InferenceApprovalStatus;
%let sourcechars=VitalCode Outcome Factor CategoryLabel Abbreviation FactorName FactorCategory InferenceMethod DenominatorDefinition Status InferenceStatus Pre_InferenceStatus Post_InferenceStatus InferenceApprovalStatus;
%let nums=OutcomeOrder CategoryCode NEligibleEvents NEligiblePatients NPreAvailableEvents NPostAvailableEvents NDiff NPairedPatients NPreOnlyEvents NPostOnlyEvents NNeitherAvailableEvents NPreWindowRecords NPostWindowRecords NPairedPreValues NPairedPostValues Pre_Mean Pre_SD Post_Mean Post_SD Diff_Mean Diff_SD WindowHalfWidthMinutes Diff_SE Diff_LCL Diff_UCL DF PValue Pre_SE Pre_DF Pre_LCL Pre_UCL Post_SE Post_DF Post_LCL Post_UCL FitPersons FitEvents FitCategories ScoreIdentityNorm;
%let expected=147;
%let source=report;
%end;
%else %if &role=observed_pairwise %then %do;
%let chars=VitalCode Outcome Factor InferenceStatus InferenceMethod InferenceApprovalStatus;
%let sourcechars=VitalCode Outcome Factor InferenceStatus InferenceMethod InferenceApprovalStatus;
%let nums=OutcomeOrder CategoryA CategoryB NEventsA NEventsB NPersonsA NPersonsB Estimate StdErr DF Lower Upper PValue FitPersons FitEvents FitCategories;
%let expected=301;
%let source=report;
%end;
%else %if &role=observed_covariance %then %do;
%let chars=VitalCode Outcome Factor InferenceStatus InferenceApprovalStatus;
%let sourcechars=VitalCode Outcome Factor InferenceStatus InferenceApprovalStatus;
%let nums=CategoryA CategoryB Covariance DF FitPersons FitEvents FitCategories;
%let expected=-1;
%let source=report;
%end;
%else %if &role=observed_joint_covariance %then %do;
%let chars=VitalCode Outcome Factor MetricA MetricB InferenceStatus InferenceApprovalStatus;
%let sourcechars=VitalCode Outcome Factor MetricA MetricB InferenceStatus InferenceApprovalStatus;
%let nums=CategoryA CategoryB Covariance DF FitPersons FitEvents FitCategories;
%let expected=-1;
%let source=report;
%end;
%else %if &role=observed_exclusions %then %do;
%let chars=Factor ReasonCode InferenceApprovalStatus;
%let sourcechars=Factor ReasonCode InferenceApprovalStatus;
%let nums=NExcludedEvents NExcludedPatients;
%let expected=-1;
%let source=report;
%end;
%else %if &role=observed_manifest %then %do;
%let chars=WindowPolicy Weighting PairingDefinition ValueScale InferenceApprovalStatus AnalysisRole ClusterUnit VarianceAdjustment IntervalDistribution JointCovarianceSource ResponseCentering;
%let sourcechars=WindowPolicy Weighting PairingDefinition ValueScale InferenceApprovalStatus AnalysisRole ClusterUnit VarianceAdjustment IntervalDistribution JointCovarianceSource ResponseCentering;
%let nums=PreLowerMinutes PreUpperMinutes PostLowerMinutes PostUpperMinutes ConfidenceLevel;
%let expected=1;
%let source=report;
%end;
%mend;
%macro rge_context;
 RunId=symget('run_id'); AnalysisSpecId=symget('analysis_spec_id'); CohortMode=symget('cohort_mode');
 InputSnapshotId=symget('input_snapshot_id'); CodeHash=symget('code_hash'); ConfigHash=symget('config_hash');
 ReportRunId=symget('report_run_id'); ReportCodeHash=symget('report_code_hash'); ReportConfigHash=symget('report_config_hash');
 ExportId=symget('export_id'); ExportCodeHash=symget('export_code_hash'); Bundle=symget('bundle');
 PopulationId=symget('population_id'); DisclosureStatus='PRIVATE_UNREVIEWED';
%mend;
%macro rbc_export_aggregate_reports(preparedlib=,reportlib=,exportlib=,
 bundle=,population_id=,run_id=,analysis_spec_id=,cohort_mode=,input_snapshot_id=,
 code_hash=,config_hash=,report_run_id=,report_code_hash=,report_config_hash=,export_id=,export_code_hash=);
 %local roles role chars sourcechars nums expected source sourcelib context i j v h rc n bad path
   sourcecontext nroles prior_decimal empty reportstatus popcount
   row1 row2 row3 row4 row5 row6 row7 row8 row9 row10 row11 row12 row13 row14 row15 row16
   row17 row18 row19 row20 row21 row22 row23 row24 row25 row26 row27 row28 row29 row30 row31 row32 row33;
 %global RBC_REPORT_EXPORT_OK RBC_REPORT_EXPORT_REASON;
 %let RBC_REPORT_EXPORT_OK=0; %let RBC_REPORT_EXPORT_REASON=NOT_COMPLETED;
 %if not %sysmacexist(rbc_export_exact_csv) %then %do;
  %rbc_report_export_reject(reason=EXACT_EXPORT_MODULE_REQUIRED); %return;
 %end;
 %if not %sysmacexist(rbc_export_exact_csv) %then %do; %rbc_report_export_reject(reason=EXACT_NUMERIC_WRITER_REQUIRED); %return; %end; %let bad=0; %let empty=0;
 %if &syscc>4 or &syserr>4 %then %do; %rbc_report_export_reject(reason=CLEAN_SESSION_REQUIRED); %return; %end;
 %if %superq(bundle) ne PREPARATION and %superq(bundle) ne POPULATION %then %do;
   %rbc_report_export_reject(reason=BUNDLE_INVALID); %return;
 %end;
 %if %superq(cohort_mode) ne development_sample and %superq(cohort_mode) ne full_cohort %then %do;
   %rbc_report_export_reject(reason=COHORT_MODE_REQUIRED); %return;
 %end;
 %if &bundle=PREPARATION %then %do;
   %let report_run_id=NOT_APPLICABLE; %let report_code_hash=NOT_APPLICABLE; %let report_config_hash=NOT_APPLICABLE;
   %if %superq(population_id) ne GLOBAL_PREPARATION %then %do;
     %rbc_report_export_reject(reason=GLOBAL_PREPARATION_SCOPE_REQUIRED); %return;
   %end;
 %end;
 %else %if %superq(population_id) ne PRIMARY and %superq(population_id) ne FIRST_EVENT and
   %superq(population_id) ne NO_FOLLOWING_UNIT_12H %then %do;
   %rbc_report_export_reject(reason=POPULATION_INVALID); %return;
 %end;
 %do i=1 %to 8;
   %let v=%scan(run_id analysis_spec_id input_snapshot_id code_hash config_hash export_id export_code_hash cohort_mode,&i);
   %if %length(%superq(&v))<1 or %length(%superq(&v))>64 or
     %sysfunc(prxmatch(/^[A-Za-z0-9_-]+$/,%superq(&v))) ne 1 %then %do;
     %rbc_report_export_reject(reason=CONTEXT_ARGUMENT_INVALID); %return;
   %end;
 %end;
 %do i=1 %to 2;
   %let v=%scan(run_id export_id,&i);
   %if %sysfunc(prxmatch(/^[0-9a-f]{32}$/,%superq(&v))) ne 1 %then %do;
     %rbc_report_export_reject(reason=RUN_EXPORT_ID_INVALID); %return;
   %end;
 %end;
 %do i=1 %to 3;
   %let v=%scan(code_hash config_hash export_code_hash,&i);
   %if %sysfunc(prxmatch(/^[0-9a-f]{64}$/,%superq(&v))) ne 1 %then %do;
     %rbc_report_export_reject(reason=HASH_ARGUMENT_INVALID); %return;
   %end;
 %end;
 %if &bundle=POPULATION %then %do;
  %if %length(%superq(report_run_id)) ne 32 or %sysfunc(prxmatch(/^[0-9a-f]{32}$/,%superq(report_run_id))) ne 1 or
    %length(%superq(report_code_hash)) ne 64 or %sysfunc(prxmatch(/^[0-9a-f]{64}$/,%superq(report_code_hash))) ne 1 or
    %length(%superq(report_config_hash)) ne 64 or %sysfunc(prxmatch(/^[0-9a-f]{64}$/,%superq(report_config_hash))) ne 1 %then %do;
    %rbc_report_export_reject(reason=REPORT_BINDING_ARGUMENTS_INVALID); %return;
  %end;
 %end;
 %do i=1 %to 3;
   %let v=%scan(preparedlib exportlib reportlib,&i);
   %if &i<3 or &bundle=POPULATION %then %do;
    %if %length(%superq(&v))<1 or %length(%superq(&v))>8 or not %sysfunc(nvalid(%superq(&v),V7)) %then %do;
      %rbc_report_export_reject(reason=LIBRARY_ARGUMENT_INVALID); %return;
    %end;
    %if %sysfunc(libref(&&&v)) ne 0 %then %do;
      %rbc_report_export_reject(reason=LIBRARY_UNASSIGNED); %return;
    %end;
   %end;
 %end;
 %if %sysfunc(fileref(_rgefile))<=0 %then %do;
   %rbc_report_export_reject(reason=FILEREF_COLLISION); %return;
 %end;
 %do i=1 %to 3;
  %let v=%scan(_rge_stage _rge_manifest _rge_unavailable,&i);
  %if %sysfunc(exist(work.&v,DATA)) or %sysfunc(exist(work.&v,VIEW)) %then %do;
    %rbc_report_export_reject(reason=SCRATCH_COLLISION); %return;
  %end;
 %end;
 %rge_schema(data=&preparedlib..pipeline_identity,
   chars=RunId AnalysisSpecId CohortMode InputSnapshotId CodeHash ConfigHash ExecutionStatus DisclosureStatus,nums=);
 %if &RBC_REPORT_EXPORT_REASON ne NOT_COMPLETED %then %return;
 %let n=0;
 data _null_;
  set &preparedlib..pipeline_identity(keep=RunId AnalysisSpecId CohortMode InputSnapshotId CodeHash ConfigHash ExecutionStatus DisclosureStatus) end=last;
  if RunId ne symget('run_id') or AnalysisSpecId ne symget('analysis_spec_id') or
    CohortMode ne symget('cohort_mode') or InputSnapshotId ne symget('input_snapshot_id') or
    CodeHash ne symget('code_hash') or ConfigHash ne symget('config_hash') or
    ExecutionStatus ne 'PREPARATION_COMPLETE' or DisclosureStatus ne 'PRIVATE_UNREVIEWED' then call symputx('bad',1,'L');
  if last then call symputx('n',_n_,'L');
 run;
 %if &n ne 1 or &bad ne 0 or &syscc>4 or &syserr>4 %then %do;
   %rbc_report_export_reject(reason=PREPARATION_IDENTITY_INVALID); %return;
 %end;
 %let roles=pipeline_identity source_flow flow_metrics flow_checks source_exclusions prepare_manifest prepare_status population_counts followup_counts;
 %if &bundle=POPULATION %then %do;
   %rge_schema(data=&reportlib..report_identity,
    chars=RunId AnalysisSpecId CohortMode InputSnapshotId CodeHash ConfigHash ReportRunId ReportCodeHash ReportConfigHash PopulationId DisclosureStatus ReportStatus,nums=);
   %if &RBC_REPORT_EXPORT_REASON ne NOT_COMPLETED %then %return;
   %let n=0;
   data _null_;
    set &reportlib..report_identity(keep=RunId AnalysisSpecId CohortMode InputSnapshotId CodeHash ConfigHash ReportRunId ReportCodeHash ReportConfigHash PopulationId DisclosureStatus ReportStatus) end=last;
    if RunId ne symget('run_id') or AnalysisSpecId ne symget('analysis_spec_id') or CohortMode ne symget('cohort_mode')
      or InputSnapshotId ne symget('input_snapshot_id') or CodeHash ne symget('code_hash') or ConfigHash ne symget('config_hash')
      or ReportRunId ne symget('report_run_id') or ReportCodeHash ne symget('report_code_hash') or ReportConfigHash ne symget('report_config_hash')
      or PopulationId ne symget('population_id') or DisclosureStatus ne 'PRIVATE_UNREVIEWED' or ReportStatus ne 'REPORTS_COMPLETE'
      then call symputx('bad',1,'L');
    if last then call symputx('n',_n_,'L');
   run;
   %if &bad ne 0 or &n ne 1 or &syscc>4 or &syserr>4 %then %do;
    %rbc_report_export_reject(reason=REPORT_IDENTITY_INVALID); %return;
   %end;
   %rge_schema(data=&reportlib..report_status,chars=PopulationId Status DisclosureStatus,nums=);
   %rge_schema(data=&preparedlib..population_counts,chars=PopulationId PopulationStatus RunId AnalysisSpecId CohortMode ExportStatus,nums=NEvents NPersons);
   %if &RBC_REPORT_EXPORT_REASON ne NOT_COMPLETED %then %return;
   %let n=0; %let reportstatus=INVALID; %let popcount=-1;
   data _null_;
     set &reportlib..report_status(keep=PopulationId Status DisclosureStatus) end=last;
     if PopulationId ne symget('population_id') or DisclosureStatus ne 'PRIVATE_UNREVIEWED'
       or Status not in ('COMPLETE','EMPTY_POPULATION') then call symputx('bad',1,'L');
     call symputx('reportstatus',Status,'L'); if last then call symputx('n',_n_,'L');
   run;
   %if &bad ne 0 or &n ne 1 %then %do; %rbc_report_export_reject(reason=REPORT_STATUS_INVALID); %return; %end;
   %let n=0;
   data _null_;
     set &preparedlib..population_counts(keep=PopulationId PopulationStatus RunId AnalysisSpecId CohortMode ExportStatus NEvents);
     where PopulationId="&population_id";
     if RunId ne symget('run_id') or AnalysisSpecId ne symget('analysis_spec_id') or CohortMode ne symget('cohort_mode')
       or ExportStatus ne 'PRIVATE_UNREVIEWED' or PopulationStatus ne 'AVAILABLE' then call symputx('bad',1,'L');
     call symputx('popcount',NEvents,'L'); call symputx('n',_n_,'L');
   run;
   %if &n ne 1 or &bad ne 0 or &popcount<0 or
      (&reportstatus=COMPLETE and &popcount=0) or (&reportstatus=EMPTY_POPULATION and &popcount ne 0) %then %do;
     %rbc_report_export_reject(reason=REPORT_POPULATION_COUNT_INVALID); %return;
   %end;
   %let roles=pipeline_identity population_counts report_identity report_status report_unavailable rdd_cohort_counts rdd_patient_sex rdd_patient_age rdd_patient_age_groups rdd_patient_ward rdd_patient_saps rdd_unit_categories rdd_units_per_person rdd_anchor_audit rdd_manifest qa_outcome_counts qa_covariate_missing qa_value_quantiles qa_record_intervals qa_duplicate_records qa_processing_status qa_source_value_quantiles observed_data_summary factor_observed_data_summary observed_pairwise observed_covariance observed_joint_covariance observed_exclusions observed_manifest;
   %if &reportstatus=EMPTY_POPULATION %then %do;
     %let empty=1; %let roles=pipeline_identity population_counts report_identity report_status report_unavailable;
   %end;
 %end;
 %let context=RunId AnalysisSpecId CohortMode InputSnapshotId CodeHash ConfigHash ReportRunId ReportCodeHash ReportConfigHash ExportId ExportCodeHash Bundle PopulationId DisclosureStatus;
 %let nroles=%sysfunc(countw(&roles));
 %do i=1 %to &nroles;
  %let role=%scan(&roles,&i); %rge_fields;
  %if &source=generated %then %let row&i=2;
  %else %do;
   %let sourcelib=&reportlib; %if &source=prepared %then %let sourcelib=&preparedlib;
   %let sourcecontext=RunId AnalysisSpecId CohortMode DisclosureStatus;
   %if &role=population_counts or &role=followup_counts %then %let sourcecontext=RunId AnalysisSpecId CohortMode ExportStatus;
   %if &role=report_status %then %let sourcecontext=PopulationId DisclosureStatus;
   %if &source=report and &role ne report_status %then %let sourcecontext=&sourcecontext PopulationId;
   %rge_schema(data=&sourcelib..&role,chars=&sourcecontext &sourcechars,nums=&nums);
   %if &RBC_REPORT_EXPORT_REASON ne NOT_COMPLETED %then %return;
   %let h=%sysfunc(open(&sourcelib..&role,i)); %let n=%sysfunc(attrn(&h,nlobs)); %let rc=%sysfunc(close(&h));
   %if &n<0 or (&expected>=0 and &n ne &expected) %then %do;
    %rbc_report_export_reject(reason=ROW_CARDINALITY_INVALID); %return;
   %end;
   %let row&i=&n;
   data _null_;
    set &sourcelib..&role(keep=&sourcecontext);
    %if &role ne report_status %then %do;
     if RunId ne %if &source=report and &role ne report_identity %then %do; symget('report_run_id') %end; %else %do; symget('run_id') %end;
       or AnalysisSpecId ne symget('analysis_spec_id') or CohortMode ne symget('cohort_mode')
       then call symputx('bad',1,'L');
    %end;
    %if &role=population_counts or &role=followup_counts %then %do;
     if ExportStatus ne 'PRIVATE_UNREVIEWED' then call symputx('bad',1,'L');
    %end;
    %else %do;
     if DisclosureStatus ne 'PRIVATE_UNREVIEWED' then call symputx('bad',1,'L');
    %end;
    %if &source=report %then %do;
     if PopulationId ne symget('population_id') then call symputx('bad',1,'L');
    %end;
   run;
   %if &bad ne 0 or &syscc>4 or &syserr>4 %then %do;
     %rbc_report_export_reject(reason=SOURCE_CONTEXT_MISMATCH); %return;
   %end;
  %end;
 %end;
 %let path=%qsysfunc(pathname(&exportlib));
 data _null_;
  %do i=1 %to %eval(&nroles+1);
    %let role=aggregate_manifest; %if &i<=&nroles %then %let role=%scan(&roles,&i);
    rc=filename('_rgefile',cats(pathname("&exportlib"),'/',"&role..csv"));
    if rc ne 0 or fexist('_rgefile') then call symputx('bad',1,'L'); rc=filename('_rgefile');
  %end;
 run;
 %if &bad ne 0 or &syscc>4 or &syserr>4 %then %do;
   %rbc_report_export_reject(reason=TARGET_NOT_FRESH); %return;
 %end;
 %let prior_decimal=%sysfunc(getoption(decimalconv,keyword));
 options decimalconv=stdieee;
 %do i=1 %to &nroles;
  %let role=%scan(&roles,&i); %rge_fields;
  %let sourcelib=&reportlib; %if &source=prepared %then %let sourcelib=&preparedlib;
  data work._rge_stage;
   retain &context &chars &nums;
   length RunId AnalysisSpecId InputSnapshotId CodeHash ConfigHash ReportRunId ReportCodeHash ReportConfigHash ExportId ExportCodeHash $64
     CohortMode DisclosureStatus $24 Bundle $16 PopulationId $32;
   %if &source=generated %then %do;
    length Item $32 AvailabilityStatus $40 ReasonCode $64;
    %rge_context;
    Item='DIAGNOSIS_SUMMARY'; AvailabilityStatus='NOT_AVAILABLE'; ReasonCode='SOURCE_FIELD_NOT_ADAPTED_TO_REPORT_INTERFACE'; output;
    Item='HOSPITAL_COUNT'; AvailabilityStatus='NOT_AVAILABLE'; ReasonCode='REVIEWED_WARD_TO_HOSPITAL_MAP_NOT_SUPPLIED'; output;
    stop;
   %end;
   %else %do;
    set &sourcelib..&role(keep=&sourcechars &nums
      %if &role=population_counts %then %do; rename=(PopulationId=ReportedPopulationId) %end; );
    %rge_context;
   %end;
   keep &context &chars &nums;
   format _numeric_ e32.; format _character_;
  run;
  data _null_;
   rc=filename('_rgefile',cats(pathname("&exportlib"),'/',"&role..csv"));
   if rc ne 0 or fexist('_rgefile') then call symputx('bad',1,'L'); rc=filename('_rgefile');
  run;
  %if &bad ne 0 or &syscc>4 or &syserr>4 %then %goto export_failed;
  filename _rgefile "%superq(path)/&role..csv" encoding='utf-8' lrecl=1048576;
  %rbc_export_exact_csv(data=work._rge_stage,fileref=_rgefile);
   %if &RBC_EXACT_CSV_OK ne 1 %then %goto export_failed;
  filename _rgefile clear;
  %if &syscc>4 or &syserr>4 %then %goto export_failed;
 %end;
 data work._rge_manifest;
  retain &context Protocol Role FileName NumericFormat TextEncoding ExportStatus RowCount ColumnCount;
  length RunId AnalysisSpecId InputSnapshotId CodeHash ConfigHash ReportRunId ReportCodeHash ReportConfigHash ExportId ExportCodeHash $64
     CohortMode DisclosureStatus $24 Bundle $16 PopulationId $32;
  length Protocol $32 Role $32 FileName $64 NumericFormat $16 TextEncoding $8 ExportStatus $24;
  %rge_context;
  Protocol='RBC_AGGREGATE_REPORTS_V2'; NumericFormat='HEX16_IEEE754'; TextEncoding='UTF-8'; ExportStatus='EXPORTED_LOCAL_ONLY';
  %do i=1 %to &nroles;
   %let role=%scan(&roles,&i); %rge_fields;
   Role="&role"; FileName="&role..csv"; RowCount=&&row&i; ColumnCount=%sysfunc(countw(&context &chars &nums)); output;
  %end;
  stop; format _numeric_ e32.;
 run;
 data _null_;
  rc=filename('_rgefile',cats(pathname("&exportlib"),'/aggregate_manifest.csv'));
  if rc ne 0 or fexist('_rgefile') then call symputx('bad',1,'L'); rc=filename('_rgefile');
 run;
 %if &bad ne 0 or &syscc>4 or &syserr>4 %then %goto export_failed;
 filename _rgefile "%superq(path)/aggregate_manifest.csv" encoding='utf-8' lrecl=1048576;
 %rbc_export_exact_csv(data=work._rge_manifest,fileref=_rgefile);
  %if &RBC_EXACT_CSV_OK ne 1 %then %goto export_failed;
 filename _rgefile clear;
 %if &syscc>4 or &syserr>4 %then %goto export_failed;
 options &prior_decimal;
 proc datasets library=work nolist; delete _rge_stage _rge_manifest; quit;
 %if &syscc>4 or &syserr>4 %then %do; %rbc_report_export_reject(reason=CLEANUP_FAILED); %return; %end;
 %let RBC_REPORT_EXPORT_OK=1; %let RBC_REPORT_EXPORT_REASON=EXPORTED_LOCAL_ONLY;
 %return;
%export_failed:
 filename _rgefile clear;
 proc datasets library=work nolist; delete _rge_stage _rge_manifest; quit;
 options &prior_decimal;
 %rbc_report_export_reject(reason=EXPORT_WRITE_FAILED);
%mend;

%macro rbc_loess_export(reportlib=,exportlib=,export_id=,export_code_hash=);
 %global RBC_LOESS_EXPORT_OK RBC_LOESS_EXPORT_REASON;
 %let RBC_LOESS_EXPORT_OK=0; %let RBC_LOESS_EXPORT_REASON=NOT_COMPLETED;
 %local i v h rc n bad role cols path reportid RBC_LOESS_REPORT_REASON oldobs oldreplace oldsyntax manifest_published;
 %let RBC_LOESS_REPORT_REASON=NOT_COMPLETED;
 %let bad=0; %let manifest_published=0;
 %if &syscc ne 0 or &syserr ne 0 %then %do; %let RBC_LOESS_EXPORT_REASON=PRIOR_SAS_FAILURE; %return; %end;
 %if %sysfunc(prxmatch(/^[0-9a-f]{32}$/,%superq(export_id))) ne 1 or
  %sysfunc(prxmatch(/^[0-9a-f]{64}$/,%superq(export_code_hash))) ne 1 %then %do;
  %let RBC_LOESS_EXPORT_REASON=EXPORT_BINDING_INVALID; %return;
 %end;
 %do i=1 %to 2;
  %let v=%scan(reportlib exportlib,&i);
  %if %length(%superq(&v))<1 or %length(%superq(&v))>8 or not %sysfunc(nvalid(%superq(&v),V7)) %then %do;
   %let RBC_LOESS_EXPORT_REASON=LIBREF_INVALID; %return;
  %end;
  %if %sysfunc(libref(&&&v)) ne 0 %then %do; %let RBC_LOESS_EXPORT_REASON=LIBREF_UNASSIGNED; %return; %end;
 %end;
 %if %sysfunc(exist(work._llexport,DATA)) or %sysfunc(exist(work._llexport,VIEW)) or
  %sysfunc(exist(work._llmanifest,DATA)) or %sysfunc(exist(work._llmanifest,VIEW)) or %sysfunc(fileref(_llfile))<=0 or %sysfunc(fileref(_llsrc))<=0 or %sysfunc(fileref(_lldst))<=0 %then %do;
  %let RBC_LOESS_EXPORT_REASON=SCRATCH_COLLISION; %return;
 %end;
 data _null_;
  if upcase(pathname("&reportlib"))=upcase(pathname("&exportlib")) then call symputx('bad',1,'L');
 run;
 %if &bad %then %do; %let RBC_LOESS_EXPORT_REASON=SEPARATE_EXPORT_LIBRARY_REQUIRED; %return; %end;
 %let path=%qsysfunc(pathname(&exportlib));
 %do i=1 %to 5;
  %let role=%scan(loess_metadata loess_status loess_support loess_predictions loess_manifest,&i);
  data _null_;
   rc=filename('_llfile',cats(pathname("&exportlib"),'/',"&role..csv"));
   if rc ne 0 or fexist('_llfile') then call symputx('bad',1,'L'); rc=filename('_llfile');
  run;
 %end;
 %if &bad or &syscc ne 0 or &syserr ne 0 %then %do; %let RBC_LOESS_EXPORT_REASON=TARGET_NOT_FRESH; %return; %end;
 %rbl_schema(ds=&reportlib..loess_metadata,chars=Protocol MethodAdoptionStatus PopulationId DisclosureStatus LoessReportId,nums=);
 %if &RBC_LOESS_REPORT_REASON ne NOT_COMPLETED %then %do; %let RBC_LOESS_EXPORT_REASON=REPORT_METADATA_INVALID; %return; %end;
 data _null_;
  rc=filename('_llfile',cats(pathname("&exportlib"),'/loess_manifest.csv.pending'));
  if rc ne 0 or fexist('_llfile') then call symputx('bad',1,'L'); rc=filename('_llfile');
 run;
 %if &bad %then %do; %let RBC_LOESS_EXPORT_REASON=TARGET_NOT_FRESH; %return; %end;
 %let n=0;
 data _null_;
  set &reportlib..loess_metadata end=last;
  if Protocol ne 'RBC_LOESS_REPORT_V1' or MethodAdoptionStatus ne 'DIRECT_DEGREE2_LOESS'
   or PopulationId ne 'PRIMARY' or DisclosureStatus ne 'PRIVATE_UNREVIEWED' then call symputx('bad',1,'L');
  if _n_=1 then call symputx('reportid',LoessReportId,'L');
  else if LoessReportId ne symget('reportid') then call symputx('bad',1,'L');
  if last then call symputx('n',_n_,'L');
 run;
 %if &bad or &n ne 7 or &syscc ne 0 or &syserr ne 0 %then %do; %let RBC_LOESS_EXPORT_REASON=REPORT_METADATA_INVALID; %return; %end;
 %rbl_schema(ds=&reportlib..loess_metadata,chars=RunId AnalysisSpecId CohortMode InputSnapshotId CodeHash ConfigHash PreparationReceiptHash ReportRunId ReportCodeHash ReportConfigHash ExportId ExportCodeHash PopulationId DisclosureStatus LoessReportId Protocol MethodId MethodAdoptionStatus VitalCode Unit UnitStatus ScaleDefinition PopulationDefinition InputWeighting ExactTimeGrouping ThinningRule GridId IntervalStatus,nums=DefaultSpanPercent SpanMin SpanMax Degree Iterations ThinningSeed GridMin GridMax GridStep);
 %if &RBC_LOESS_REPORT_REASON ne NOT_COMPLETED %then %do;
  %let RBC_LOESS_EXPORT_REASON=SOURCE_SCHEMA_INVALID; %goto failed;
 %end;
 data work._llexport;
  retain RunId AnalysisSpecId CohortMode InputSnapshotId CodeHash ConfigHash PreparationReceiptHash ReportRunId ReportCodeHash ReportConfigHash ExportId ExportCodeHash PopulationId DisclosureStatus LoessReportId Protocol MethodId MethodAdoptionStatus VitalCode Unit UnitStatus ScaleDefinition PopulationDefinition InputWeighting ExactTimeGrouping ThinningRule GridId IntervalStatus DefaultSpanPercent SpanMin SpanMax Degree Iterations ThinningSeed GridMin GridMax GridStep;
  set &reportlib..loess_metadata(keep=RunId AnalysisSpecId CohortMode InputSnapshotId CodeHash ConfigHash PreparationReceiptHash ReportRunId ReportCodeHash ReportConfigHash ExportId ExportCodeHash PopulationId DisclosureStatus LoessReportId Protocol MethodId MethodAdoptionStatus VitalCode Unit UnitStatus ScaleDefinition PopulationDefinition InputWeighting ExactTimeGrouping ThinningRule GridId IntervalStatus DefaultSpanPercent SpanMin SpanMax Degree Iterations ThinningSeed GridMin GridMax GridStep);
  ExportId="&export_id"; ExportCodeHash="&export_code_hash";
  keep RunId AnalysisSpecId CohortMode InputSnapshotId CodeHash ConfigHash PreparationReceiptHash ReportRunId ReportCodeHash ReportConfigHash ExportId ExportCodeHash PopulationId DisclosureStatus LoessReportId Protocol MethodId MethodAdoptionStatus VitalCode Unit UnitStatus ScaleDefinition PopulationDefinition InputWeighting ExactTimeGrouping ThinningRule GridId IntervalStatus DefaultSpanPercent SpanMin SpanMax Degree Iterations ThinningSeed GridMin GridMax GridStep; format _character_;
 run;
 %let h=%sysfunc(open(work._llexport,i)); %let n=%sysfunc(attrn(&h,nlobs)); %let rc=%sysfunc(close(&h));
 %if &n ne 7 or &syscc ne 0 or &syserr ne 0 %then %do; %let RBC_LOESS_EXPORT_REASON=SOURCE_CARDINALITY_INVALID; %goto failed; %end;
 filename _llfile "%superq(path)/loess_metadata.csv" encoding='utf-8' lrecl=1048576;
 %rbc_export_exact_csv(data=work._llexport,fileref=_llfile);
 filename _llfile clear;
 %if &RBC_EXACT_CSV_OK ne 1 or &syscc ne 0 or &syserr ne 0 %then %do; %let RBC_LOESS_EXPORT_REASON=EXPORT_WRITE_FAILED; %goto failed; %end;
 %rbl_schema(ds=&reportlib..loess_status,chars=LoessReportId VitalCode FitStatus PointStatusPolicy,nums=SpanPercent);
 %if &RBC_LOESS_REPORT_REASON ne NOT_COMPLETED %then %do;
  %let RBC_LOESS_EXPORT_REASON=SOURCE_SCHEMA_INVALID; %goto failed;
 %end;
 data work._llexport;
  retain LoessReportId VitalCode SpanPercent FitStatus PointStatusPolicy;
  set &reportlib..loess_status(keep=LoessReportId VitalCode SpanPercent FitStatus PointStatusPolicy);
  keep LoessReportId VitalCode SpanPercent FitStatus PointStatusPolicy; format _character_;
 run;
 %let h=%sysfunc(open(work._llexport,i)); %let n=%sysfunc(attrn(&h,nlobs)); %let rc=%sysfunc(close(&h));
 %if &n ne 567 or &syscc ne 0 or &syserr ne 0 %then %do; %let RBC_LOESS_EXPORT_REASON=SOURCE_CARDINALITY_INVALID; %goto failed; %end;
 filename _llfile "%superq(path)/loess_status.csv" encoding='utf-8' lrecl=1048576;
 %rbc_export_exact_csv(data=work._llexport,fileref=_llfile);
 filename _llfile clear;
 %if &RBC_EXACT_CSV_OK ne 1 or &syscc ne 0 or &syserr ne 0 %then %do; %let RBC_LOESS_EXPORT_REASON=EXPORT_WRITE_FAILED; %goto failed; %end;
 %rbl_schema(ds=&reportlib..loess_support,chars=LoessReportId VitalCode SupportStage CountUnit OverlapSemantics DisclosureStatus,nums=NRows NKnownPersons NKnownEvents NAvailableOutcome NExactTimeGroups NRetainedTimeGroups);
 %if &RBC_LOESS_REPORT_REASON ne NOT_COMPLETED %then %do;
  %let RBC_LOESS_EXPORT_REASON=SOURCE_SCHEMA_INVALID; %goto failed;
 %end;
 data work._llexport;
  retain LoessReportId VitalCode SupportStage CountUnit OverlapSemantics DisclosureStatus NRows NKnownPersons NKnownEvents NAvailableOutcome NExactTimeGroups NRetainedTimeGroups;
  set &reportlib..loess_support(keep=LoessReportId VitalCode SupportStage CountUnit OverlapSemantics DisclosureStatus NRows NKnownPersons NKnownEvents NAvailableOutcome NExactTimeGroups NRetainedTimeGroups);
  keep LoessReportId VitalCode SupportStage CountUnit OverlapSemantics DisclosureStatus NRows NKnownPersons NKnownEvents NAvailableOutcome NExactTimeGroups NRetainedTimeGroups; format _character_;
 run;
 %let h=%sysfunc(open(work._llexport,i)); %let n=%sysfunc(attrn(&h,nlobs)); %let rc=%sysfunc(close(&h));
 %if &n ne 35 or &syscc ne 0 or &syserr ne 0 %then %do; %let RBC_LOESS_EXPORT_REASON=SOURCE_CARDINALITY_INVALID; %goto failed; %end;
 filename _llfile "%superq(path)/loess_support.csv" encoding='utf-8' lrecl=1048576;
 %rbc_export_exact_csv(data=work._llexport,fileref=_llfile);
 filename _llfile clear;
 %if &RBC_EXACT_CSV_OK ne 1 or &syscc ne 0 or &syserr ne 0 %then %do; %let RBC_LOESS_EXPORT_REASON=EXPORT_WRITE_FAILED; %goto failed; %end;
 %rbl_schema(ds=&reportlib..loess_predictions,chars=LoessReportId MethodId VitalCode GridId ValueScale Unit UnitStatus PointStatus IntervalStatus SupportStatus DisclosureStatus MethodAdoptionStatus,nums=SpanPercent GridPointId TimeFromTransfusion Estimate);
 %if &RBC_LOESS_REPORT_REASON ne NOT_COMPLETED %then %do;
  %let RBC_LOESS_EXPORT_REASON=SOURCE_SCHEMA_INVALID; %goto failed;
 %end;
 data work._llexport;
  retain LoessReportId MethodId VitalCode SpanPercent GridId GridPointId TimeFromTransfusion ValueScale Unit UnitStatus Estimate PointStatus IntervalStatus SupportStatus DisclosureStatus MethodAdoptionStatus;
  set &reportlib..loess_predictions(keep=LoessReportId MethodId VitalCode SpanPercent GridId GridPointId TimeFromTransfusion ValueScale Unit UnitStatus Estimate PointStatus IntervalStatus SupportStatus DisclosureStatus MethodAdoptionStatus);
  keep LoessReportId MethodId VitalCode SpanPercent GridId GridPointId TimeFromTransfusion ValueScale Unit UnitStatus Estimate PointStatus IntervalStatus SupportStatus DisclosureStatus MethodAdoptionStatus; format _character_;
 run;
 %let h=%sysfunc(open(work._llexport,i)); %let n=%sysfunc(attrn(&h,nlobs)); %let rc=%sysfunc(close(&h));
 %if &n ne 1634094 or &syscc ne 0 or &syserr ne 0 %then %do; %let RBC_LOESS_EXPORT_REASON=SOURCE_CARDINALITY_INVALID; %goto failed; %end;
 filename _llfile "%superq(path)/loess_predictions.csv" encoding='utf-8' lrecl=1048576;
 %rbc_export_exact_csv(data=work._llexport,fileref=_llfile);
 filename _llfile clear;
 %if &RBC_EXACT_CSV_OK ne 1 or &syscc ne 0 or &syserr ne 0 %then %do; %let RBC_LOESS_EXPORT_REASON=EXPORT_WRITE_FAILED; %goto failed; %end;
 data work._llmanifest;
  retain Protocol LoessReportId ExportId ExportCodeHash Role FileName NumericFormat TextEncoding ExportStatus RowCount ColumnCount;
  length Protocol $32 LoessReportId ExportId ExportCodeHash $64 Role $32 FileName $64 NumericFormat $24 TextEncoding $8 ExportStatus $32;
  Protocol='RBC_LOESS_REPORT_V1'; LoessReportId="&reportid"; ExportId="&export_id"; ExportCodeHash="&export_code_hash";
  NumericFormat='HEX16_IEEE754'; TextEncoding='UTF-8'; ExportStatus='EXPORTED_LOCAL_ONLY';
  Role='loess_metadata'; FileName='loess_metadata.csv'; RowCount=7; ColumnCount=37; output;
  Role='loess_status'; FileName='loess_status.csv'; RowCount=567; ColumnCount=5; output;
  Role='loess_support'; FileName='loess_support.csv'; RowCount=35; ColumnCount=12; output;
  Role='loess_predictions'; FileName='loess_predictions.csv'; RowCount=1634094; ColumnCount=16; output;
  stop;
 run;
 filename _llfile "%superq(path)/loess_manifest.csv.pending" encoding='utf-8' lrecl=1048576;
 %rbc_export_exact_csv(data=work._llmanifest,fileref=_llfile);
 filename _llfile clear;
 %if &RBC_EXACT_CSV_OK ne 1 or &syscc ne 0 or &syserr ne 0 %then %do; %let RBC_LOESS_EXPORT_REASON=MANIFEST_WRITE_FAILED; %goto failed; %end;
 proc datasets library=work nolist; delete _llexport _llmanifest; quit;
 %if &syscc ne 0 or &syserr ne 0 %then %do; %let RBC_LOESS_EXPORT_REASON=CLEANUP_FAILED; %goto failed; %end;
  
 data _null_;
  rc=filename('_llsrc',cats(pathname("&exportlib"),'/loess_manifest.csv.pending'));
  rc2=filename('_lldst',cats(pathname("&exportlib"),'/loess_manifest.csv'));
  if rc ne 0 or rc2 ne 0 or not fexist('_llsrc') or fexist('_lldst') then call symputx('bad',1,'L');
  else do; rc=rename(pathname('_llsrc'),pathname('_lldst'),'file'); if rc ne 0 then call symputx('bad',1,'L'); else call symputx('manifest_published',1,'L'); end;
  rc=filename('_llsrc');rc=filename('_lldst');
 run;
 %if &bad or &syscc ne 0 or &syserr ne 0 %then %do; %let RBC_LOESS_EXPORT_REASON=MANIFEST_PUBLICATION_FAILED; %goto failed; %end;
 %let RBC_LOESS_EXPORT_OK=1; %let RBC_LOESS_EXPORT_REASON=EXPORTED_LOCAL_ONLY;
 %return;
 %failed:
 %let oldobs=%sysfunc(getoption(obs,keyword));
 %let oldreplace=%sysfunc(getoption(replace,keyword));
 %let oldsyntax=%sysfunc(getoption(syntaxcheck,keyword));
 options obs=max replace nosyntaxcheck;
 filename _llfile clear;
 filename _llsrc clear;
 filename _lldst clear;
 proc datasets library=work nolist; delete _llexport _llmanifest; quit;
 data _null_;
  length target $1024;
  do suffix='loess_manifest.csv.pending','loess_manifest.csv';
   target=cats(pathname("&exportlib"),'/',suffix);rc=filename('_llfile',target);
   if rc=0 and fexist('_llfile') and (suffix='loess_manifest.csv.pending' or &manifest_published=1) then rc=fdelete('_llfile'); rc=filename('_llfile');
  end;
 run;
 options &oldobs &oldreplace &oldsyntax;
%mend;

