/* Sequential analysis entry point.
   Configuration and local directories are supplied by run.py.
   Files 00 through 06 define the main analyses. File 07 computes the weekday contrasts.
*/
options nosource nosource2 nomprint nomlogic nosymbolgen cpucount=&SAS_CPU_COUNT;
ods _all_ close;
%global ANALYSIS_STATUS;
%let ANALYSIS_STATUS=RUNNING;
%macro analysis_fail(code);
  %let ANALYSIS_STATUS=FAILED;
  %put ERROR: ANALYSIS_FAILED &code;
  %abort cancel;
%mend;
%macro analysis_check(stage);
  %if &syscc>4 or &syserr>4 %then %analysis_fail(SAS_STEP_FAILED);
%mend;
%macro load_scientific_code;
  %include "&PACKAGE_ROOT./sas/00_categories.sas";
  %include "&PACKAGE_ROOT./sas/01_cohort.sas";
  %include "&PACKAGE_ROOT./sas/02_summaries.sas";
  %include "&PACKAGE_ROOT./sas/03_models.sas";
  %include "&PACKAGE_ROOT./sas/04_inference.sas";
  %include "&PACKAGE_ROOT./sas/05_loess.sas";
  %include "&PACKAGE_ROOT./sas/06_exports.sas";
%mend;
%load_scientific_code;
%macro run_model;
  %local prefix;
  %let prefix=C%substr(&CTX_JobID,2);
  %if not ((&CTX_CohortMode=development_sample and &CTX_InferenceScope=LOCAL_SAMPLE_MODEL_INFERENCE) or
           (&CTX_CohortMode=full_cohort and &CTX_InferenceScope=FULL_COHORT_MODEL_INFERENCE))
    %then %do; %analysis_fail(SCOPE_COHORT_MISMATCH); %return; %end;
   %if &ANALYSIS_STATUS ne RUNNING %then %return;
   
  proc sql;
    create table work._rpipe_jobdata as select a.PersonKey,a.PatientID,a.RBC_EventKey,a.ICUAdmissionKey,a.VitalCode,
      a.Value,a.TimeFromTransfusion,a.PatientAge,a.PatientSex,a.WardName,a.RBC_Count,a.ICU_time,
      a.Crystalloid_1,a.Crystalloid_24,a.Pressors_1,a.Pressors_24,a.Sedatives_1_bin,a.Sedatives_24_bin,
      a.DonorHb_Cat,a.Storage_Cat,a.DonorSex,a.DonorParity_Female,a.wdy_donation
      from prep.canonical_long a inner join prep.population_members p on a.RBC_EventKey=p.RBC_EventKey
      where p.PopulationId="&CTX_PopulationId" and upcase(a.VitalCode)=upcase("&CTX_VitalCode");
  quit;
  %analysis_check; %if &ANALYSIS_STATUS ne RUNNING %then %return;
   %if &ANALYSIS_STATUS ne RUNNING %then %return;
  %rbc_fit_job(data=work._rpipe_jobdata,outlib=model,job_id=&CTX_JobID,
    vital=&CTX_VitalCode,factor=&CTX_FactorName,adjustment=&CTX_Model,
    score_subject=-1,keep_scratch=1,optimizer_restart=&CTX_OptimizerRestart,
    run_id=&CTX_RunId,analysis_spec_id=&CTX_AnalysisSpecId,cohort_mode=&CTX_CohortMode,
    population_id=&CTX_PopulationId,fit_id=&CTX_FitId,input_snapshot_id=&CTX_InputSnapshotId,
    code_hash=&CTX_CodeHash,config_hash=&CTX_ConfigHash,design_id=&CTX_DesignId,profile_id=&CTX_ProfileId);
  %analysis_check; %if &ANALYSIS_STATUS ne RUNNING %then %return;
  %if not %symexist(RBC_FIT_STATUS) %then %do; %analysis_fail(FIT_STATUS_REQUIRED); %return; %end;
  %if &RBC_FIT_STATUS ne FIT_CHECKS_PASSED and &RBC_FIT_STATUS ne EXPECTED_UNAVAILABLE
    %then %do; %analysis_fail(FIT_REJECTED); %return; %end;
   %if &ANALYSIS_STATUS ne RUNNING %then %return;
  %rbc_export_model_archive(outlib=model,job_id=&CTX_JobID,exportlib=mcsv);
  %analysis_check; %if &ANALYSIS_STATUS ne RUNNING %then %return;
  %if not %symexist(RBC_ARCHIVE_OK) %then %do; %analysis_fail(MODEL_EXPORT_STATUS_REQUIRED); %return; %end;
  %if &RBC_ARCHIVE_OK ne 1 %then %do; %analysis_fail(MODEL_EXPORT_REJECTED); %return; %end;
  %if &RBC_FIT_STATUS=FIT_CHECKS_PASSED %then %do;
   %if &ANALYSIS_STATUS ne RUNNING %then %return;
    %rbc_cr2_white_integration(model_lib=model,job_id=&CTX_JobID,design=work._rbc_design,
      outlib=cr2,prefix=&prefix,scope=&CTX_InferenceScope,alpha=.05,certificate_hash=&CTX_CertificateCodeHash,
      scalar_policy=&CTX_ScalarPolicy);
    %analysis_check; %if &ANALYSIS_STATUS ne RUNNING %then %return;
    %if not %symexist(RBC_CR2_INTEGRATION_OK) %then %do; %analysis_fail(CR2_STATUS_REQUIRED); %return; %end;
    %if &RBC_CR2_INTEGRATION_OK ne 1 %then %do;

      %if &CTX_StructuralPolicy ne SINGLE_PERSON_CATEGORY_CR2_UNAVAILABLE_V1 or
          %superq(RBC_CR2_INTEGRATION_REASON) ne PLANNED_TARGET_NOT_LOO_ESTIMABLE %then %do;
        %analysis_fail(CR2_REJECTED); %return;
      %end;
       %if &ANALYSIS_STATUS ne RUNNING %then %return;
      %rbc_cr2_structural_unavailable(model_lib=model,job_id=&CTX_JobID,source_lib=cr2,prefix=&prefix,
        outlib=cr2,scope=&CTX_InferenceScope,policy=&CTX_StructuralPolicy,
        integration_reason=%superq(RBC_CR2_INTEGRATION_REASON));
      %analysis_check; %if &ANALYSIS_STATUS ne RUNNING %then %return;
      %if not %symexist(RBC_IU_OK) %then %do; %analysis_fail(CR2_UNAVAILABLE_STATUS_REQUIRED); %return; %end;
      %if &RBC_IU_OK ne 1 %then %do; %analysis_fail(CR2_UNAVAILABLE_REJECTED); %return; %end;
      %rbc_export_cr2_iu(outlib=cr2,prefix=&prefix,exportlib=ccsv);
      %analysis_check; %if &ANALYSIS_STATUS ne RUNNING %then %return;
      %if not %symexist(RBC_IU_EXPORT_OK) %then %do; %analysis_fail(CR2_UNAVAILABLE_EXPORT_STATUS_REQUIRED); %return; %end;
      %if &RBC_IU_EXPORT_OK ne 1 %then %analysis_fail(CR2_UNAVAILABLE_EXPORT_REJECTED);
      %return;
    %end;

    %if &CTX_StructuralPolicy=SINGLE_PERSON_CATEGORY_CR2_UNAVAILABLE_V1 %then %do;
      %rbc_cr2_spcu_pass_guard(model_lib=model,job_id=&CTX_JobID,source_lib=cr2,prefix=&prefix,
        scope=&CTX_InferenceScope,policy=&CTX_StructuralPolicy);
      %analysis_check; %if &ANALYSIS_STATUS ne RUNNING %then %return;
      %if not %symexist(RBC_IU_GUARD_OK) %then %do; %analysis_fail(CR2_SUPPORT_GUARD_STATUS_REQUIRED); %return; %end;
      %if &RBC_IU_GUARD_OK ne 1 %then %do; %analysis_fail(CR2_SUPPORT_GUARD_REJECTED); %return; %end;
    %end;
   %if &ANALYSIS_STATUS ne RUNNING %then %return;
    %rbc_export_cr2_white_archive(outlib=cr2,prefix=&prefix,exportlib=ccsv,scalar_policy=&CTX_ScalarPolicy);
    %analysis_check; %if &ANALYSIS_STATUS ne RUNNING %then %return;
    %if not %symexist(RBC_CR2_EXPORT_OK) %then %do; %analysis_fail(CR2_EXPORT_STATUS_REQUIRED); %return; %end;
    %if &RBC_CR2_EXPORT_OK ne 1 %then %analysis_fail(CR2_EXPORT_REJECTED);
  %end;
%mend;

%macro run_report;
   %if &ANALYSIS_STATUS ne RUNNING %then %return;
  %if &CTX_Bundle=POPULATION %then %do;
    %rbc_refresh_population_report(preparedlib=prep,outlib=rpt,population_id=&CTX_PopulationId,
      run_id=&CTX_RunId,analysis_spec_id=&CTX_AnalysisSpecId,cohort_mode=&CTX_CohortMode,
      input_snapshot_id=&CTX_InputSnapshotId,code_hash=&CTX_CodeHash,config_hash=&CTX_ConfigHash,
      report_run_id=&CTX_ReportRunId,report_code_hash=&CTX_ReportCodeHash,
      report_config_hash=&CTX_ReportConfigHash,oxygen_units=&CTX_OxygenUnits);
    %analysis_check; %if &ANALYSIS_STATUS ne RUNNING %then %return;
    %if not %symexist(RBC_REFRESH_OK) %then %do; %analysis_fail(REPORT_STATUS_REQUIRED); %return; %end;
    %if &RBC_REFRESH_OK ne 1 %then %do; %analysis_fail(REPORT_REJECTED); %return; %end;
  %end;
   %if &ANALYSIS_STATUS ne RUNNING %then %return;
  %rbc_export_aggregate_reports(preparedlib=prep,reportlib=rpt,exportlib=csvout,
    bundle=&CTX_Bundle,population_id=&CTX_PopulationId,
    run_id=&CTX_RunId,analysis_spec_id=&CTX_AnalysisSpecId,cohort_mode=&CTX_CohortMode,
    input_snapshot_id=&CTX_InputSnapshotId,code_hash=&CTX_CodeHash,config_hash=&CTX_ConfigHash,
    report_run_id=&CTX_ReportRunId,report_code_hash=&CTX_ReportCodeHash,
    report_config_hash=&CTX_ReportConfigHash,export_id=&CTX_ExportId,export_code_hash=&CTX_ExportCodeHash);
  %analysis_check; %if &ANALYSIS_STATUS ne RUNNING %then %return;
  %if not %symexist(RBC_REPORT_EXPORT_OK) %then %do; %analysis_fail(REPORT_EXPORT_STATUS_REQUIRED); %return; %end;
  %if &RBC_REPORT_EXPORT_OK ne 1 %then %analysis_fail(REPORT_EXPORT_REJECTED);
%mend;

%macro report_definitions;
   
  data RBPREP.age_bands;
    length BandCode $32 BandLabel $64;
    do BandOrder=1 to 8;
      if BandOrder=1 then do; LowerBound=.; UpperBound=20; BandCode='LT20'; BandLabel='<20'; end;
      else if BandOrder=8 then do; LowerBound=80; UpperBound=.; BandCode='GE80'; BandLabel='80+'; end;
      else do;
        LowerBound=BandOrder*10; UpperBound=LowerBound+10;
        BandCode=cats('AGE',LowerBound,'_',UpperBound-1); BandLabel=cats(LowerBound,'-',UpperBound-1);
      end;
      output;
    end;
  run;
  data RBPREP.factor_levels;
    length Factor $32 CategoryLabel $128;
    Factor='MAIN'; CategoryCode=1; CategoryLabel='All eligible events'; output;
    Factor='DonorHb_Cat'; do CategoryCode=1 to 5;
      CategoryLabel=scan('<125|125-<140|140-<155|155-<170|>=170',CategoryCode,'|'); output;
    end;
    Factor='Storage_Cat'; do CategoryCode=1 to 5;
      CategoryLabel=scan('<10|10-<20|20-<30|30-<40|>=40',CategoryCode,'|'); output;
    end;
    Factor='DonorSex'; CategoryCode=1; CategoryLabel='Male'; output;
    CategoryCode=2; CategoryLabel='Female'; output;
    Factor='DonorParity_Female'; CategoryCode=0; CategoryLabel='Female donor parity 0'; output;
    CategoryCode=1; CategoryLabel='Female donor parity 1'; output;
    Factor='wdy_donation'; do CategoryCode=1 to 7;
      CategoryLabel=scan('Sunday Monday Tuesday Wednesday Thursday Friday Saturday',CategoryCode,' '); output;
    end;
  run;
  %analysis_check(CONFIGURATION_TABLES);
%mend;

%macro preparation_identity(out=);
  data &out;
    length RunId AnalysisSpecId InputSnapshotId CodeHash ConfigHash $64 CohortMode $24
      SourceMember $32 CoverageStatus $40 UnitStatus $24 ExecutionStatus $40
      DisclosureStatus $24 AgeBandDefinition $64 SourceYearBoundsMeaning $64;
    RunId=symget('CFG_RUN_ID'); AnalysisSpecId=symget('CFG_ANALYSIS_SPEC_ID');
    InputSnapshotId=symget('CFG_INPUT_SNAPSHOT_ID'); CodeHash=symget('CFG_CODE_HASH');
    ConfigHash=symget('CFG_CONFIG_HASH'); CohortMode=symget('CFG_COHORT_MODE');
    SourceMember=symget('CFG_INPUT_MEMBER'); DisclosureStatus='PRIVATE_UNREVIEWED';
    CoverageStatus='UNVERIFIED_CODE_LINEAGE_ONLY';
    if upcase(symget('CFG_COVERAGE_VERIFIED'))='YES' then do;
      if symget('CFG_COVERAGE_SCOPE')='RECORDED_RBC_EXTRACTION_1973_2018'
        then CoverageStatus='RECORDED_SOURCE_PERIOD_DEFINED';
      else CoverageStatus='EXTERNAL_PERSON_COVERAGE_VERIFIED';
    end;

    UnitStatus=upcase(symget('CFG_UNITS_VERIFIED'));
    ExecutionStatus='PREPARATION_COMPLETE';
    AgeBandDefinition='LEGACY_LT20_THEN_DECADES_TO_GE80_MISSING_SEPARATE';
    SourceExtractFirstYear=1973; SourceExtractLastYear=2018;
    SourceYearBoundsMeaning='CODE_EXTRACT_YEARS_NOT_PROOF_OF_PERSON_FOLLOWUP';
  run;
  %analysis_check(IDENTITY_WRITE);
%mend;

%macro prepare_analysis;
  libname source "&INPUT_DIRECTORY" access=readonly;
  libname RBPREP "&OUTPUT_DIRECTORY./prepared";
  %analysis_check;
  %rbc_prepare_source(index=source.&MEASUREMENTS_MEMBER,ledger=source.&TRANSFUSIONS_MEMBER,
    admissions=source.&ADMISSIONS_MEMBER,outlib=RBPREP,run_id=&CTX_RunId,
    input_snapshot_id=&CTX_InputSnapshotId,code_hash=&CTX_CodeHash,config_hash=&CTX_ConfigHash,
    analysis_spec_id=&CTX_AnalysisSpecId,cohort_mode=&CTX_CohortMode,
    model_grouping=PERSON,donation_date_unit=DATETIME,
    medication_reconciliation=FLOAT32_SED24_REL12,science_frozen=&CFG_SCIENCE_FROZEN);
  %if &RBC_PREPARE_OK ne 1 %then %analysis_fail(SOURCE_PREPARATION_FAILED);
  libname source clear;
  %report_definitions;
  proc sql;
    create table RBPREP.recorded_coverage as select distinct PersonKey,
      '01JAN1973:00:00:00'dt as CoverageStart,'01JAN2019:00:00:00'dt as CoverageEnd
      from RBPREP.canonical_events;
  quit;
  %analysis_check;
  %rbc_make_populations(events=RBPREP.canonical_events,units=RBPREP.canonical_units,
    coverage=RBPREP.recorded_coverage,outlib=RBPREP,run_id=&CTX_RunId,
    analysis_spec_id=&CTX_AnalysisSpecId,cohort_mode=&CTX_CohortMode,
    mapping_verified=YES,primary_eligibility_verified=YES,coverage_verified=YES,
    end_boundary=EXCLUSIVE,coverage_scope=RECORDED_RBC_EXTRACTION_1973_2018);
  %if &RBC_POPULATIONS_OK ne 1 %then %analysis_fail(POPULATION_BUILD_FAILED);
  %preparation_identity(out=RBPREP.pipeline_identity);
  libname RBPREP clear;
%mend;

%macro run_loess;
  %rbc_loess_report(preparedlib=prep,outlib=rpt,run_id=&CTX_RunId,
    analysis_spec_id=&CTX_AnalysisSpecId,cohort_mode=&CTX_CohortMode,
    input_snapshot_id=&CTX_InputSnapshotId,code_hash=&CTX_CodeHash,config_hash=&CTX_ConfigHash,
    preparation_receipt_hash=&CTX_PreparationReceiptHash,report_run_id=&CTX_ReportRunId,
    report_code_hash=&CTX_ReportCodeHash,report_config_hash=&CTX_ReportConfigHash);
  %analysis_check;
  %if &RBC_LOESS_REPORT_OK ne 1 %then %analysis_fail(LOESS_REJECTED);
  %rbc_loess_export(reportlib=rpt,exportlib=csvout,export_id=&CTX_ExportId,
    export_code_hash=&CTX_ExportCodeHash);
  %analysis_check;
  %if &RBC_LOESS_EXPORT_OK ne 1 %then %analysis_fail(LOESS_EXPORT_REJECTED);
%mend;

%macro execute_analysis_step;
  %if &TASK=PREPARE %then %prepare_analysis;
  %else %if &TASK=MODEL %then %run_model;
  %else %if &TASK=REPORT %then %run_report;
  %else %if &TASK=LOESS %then %run_loess;
  %else %if &TASK=CHECK %then %do;
    %if not %sysmacexist(rbc_fit_job) or not %sysmacexist(rbc_cr2_white_integration)
      or not %sysmacexist(rbc_prepare_source) or not %sysmacexist(rbc_loess_report)
      %then %analysis_fail(SCIENTIFIC_MACRO_NOT_LOADED);
  %end;
  %else %analysis_fail(UNKNOWN_ANALYSIS_STEP);
  %analysis_check;
  data _null_;
    file "&STEP_DIRECTORY./completed.txt";
    put 'ANALYSIS_STEP_COMPLETE';
  run;
%mend;
%execute_analysis_step;

