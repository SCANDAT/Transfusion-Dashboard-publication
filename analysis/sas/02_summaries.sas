/* Descriptive and observed analyses.
   Patient and component descriptors, quality diagnostics, paired observed window summaries with patient-cluster inference, and population-report assembly.
   This file defines macros; use run.py to execute the analysis steps.
*/
%macro qad_fail(code);
  %let RBC_QA_OK=0;
  %let RBC_QA_ERROR=&code;
  %put NOTE: RBC_QA_REJECTED &code;
%mend;
%macro qad_step(stage);
  %if &syserr>4 or &syscc>4 %then %qad_fail(STEP_FAILED_&stage);
%mend;
%macro qad_require(ds=,vars=,types=);
  %local lib mem h i pos actual rc;
  %if %sysfunc(countc(%superq(ds),.)) ne 1 %then %do;
    %qad_fail(SIMPLE_TWO_LEVEL_DATA_NAME_REQUIRED); %return;
  %end;
  %let lib=%qscan(%superq(ds),1,.); %let mem=%qscan(%superq(ds),2,.);
  %if %length(%superq(lib))>8 or %length(%superq(mem))>32 or
      not %sysfunc(nvalid(%superq(lib),V7)) or
      not %sysfunc(nvalid(%superq(mem),V7)) %then %do;
    %qad_fail(SIMPLE_TWO_LEVEL_DATA_NAME_REQUIRED); %return;
  %end;
  %if not %sysfunc(exist(&ds,DATA)) %then %do;
    %qad_fail(INPUT_DATA_TABLE_REQUIRED); %return;
  %end;
  %let h=%sysfunc(open(&ds,i));
  %if &h=0 %then %do; %qad_fail(INPUT_METADATA_UNAVAILABLE); %return; %end;
  %do i=1 %to %sysfunc(countw(&vars));
    %let pos=%sysfunc(varnum(&h,%scan(&vars,&i)));
    %if &pos=0 %then %do;
      %let rc=%sysfunc(close(&h)); %qad_fail(REQUIRED_COLUMN_ABSENT); %return;
    %end;
    %let actual=%sysfunc(vartype(&h,&pos));
    %if &actual ne %scan(&types,&i) %then %do;
      %let rc=%sysfunc(close(&h)); %qad_fail(REQUIRED_COLUMN_TYPE_MISMATCH); %return;
    %end;
    %if &actual=C %then %do;
      %if %sysfunc(varlen(&h,&pos))>256 %then %do;
        %let rc=%sysfunc(close(&h)); %qad_fail(CHARACTER_FIELD_TOO_LONG); %return;
      %end;
    %end;
  %end;
  %let rc=%sysfunc(close(&h));
%mend;

%macro rbc_quality_diagnostics(data=,outlib=,run_id=,analysis_spec_id=,
    cohort_mode=,population_id=,mapping_verified=,oxygen_units=,
    recordings=,recording_scope=,recording_keys_verified=,recording_population_id=,on_error=ABORT);
  %global RBC_QA_OK RBC_QA_ERROR;
  %local i v name idvar outnames stages scratchnames nbad ncov covars nnum
      numvars made published existing have_source;
  %let RBC_QA_OK=0; %let RBC_QA_ERROR=NONE; %let made=0; %let published=0;
  %let have_source=0;
  %let outnames=qa_outcome_counts qa_covariate_missing qa_value_quantiles
      qa_record_intervals qa_duplicate_records qa_processing_status qa_source_value_quantiles;
  %let stages=_qad_outcome _qad_missing _qad_values _qad_intervals
      _qad_duplicates _qad_status _qad_srcvalues;
  %let scratchnames=_qad_data _qad_source _qad_codes _qad_counts _qad_valraw
      _qad_aduptmp _qad_adupcounts _qad_sdupkeys _qad_sadm _qad_sadmdup
      _qad_ssort _qad_spositions _qad_scount _qad_squant _qad_svraw &stages;
  %if &syscc>4 %then %do; %qad_fail(FRESH_SAS_SESSION_REQUIRED); %goto finish; %end;
  %if %upcase(%superq(on_error)) ne ABORT and %upcase(%superq(on_error)) ne RETURN
    %then %do; %qad_fail(ERROR_POLICY_REQUIRED); %goto finish; %end;
  %if %upcase(%superq(mapping_verified)) ne YES or
      (%upcase(%superq(oxygen_units)) ne PERCENT and %upcase(%superq(oxygen_units)) ne UNVERIFIED)
    %then %do; %qad_fail(EXPLICIT_CANONICAL_MAPPING_AND_OXYGEN_UNITS_REQUIRED); %goto finish; %end;
  %if %superq(cohort_mode) ne development_sample and %superq(cohort_mode) ne full_cohort
    %then %do; %qad_fail(COHORT_MODE_REQUIRED); %goto finish; %end;
   
  %if %superq(cohort_mode)=full_cohort and %upcase(%superq(oxygen_units)) ne UNVERIFIED
    %then %do; %qad_fail(FULL_COHORT_NATIVE_OXYGEN_UNITS_REQUIRED); %goto finish; %end;
  %if %superq(population_id) ne PRIMARY and %superq(population_id) ne FIRST_EVENT and
      %superq(population_id) ne NO_FOLLOWING_UNIT_12H
    %then %do; %qad_fail(POPULATION_ID_REQUIRED); %goto finish; %end;
  %do i=1 %to 2;
    %let idvar=%scan(run_id analysis_spec_id,&i);
    %if %length(%superq(&idvar))=0 or %length(%superq(&idvar))>64 or
        %sysfunc(prxmatch(/^[A-Za-z0-9_-]+$/,%superq(&idvar))) ne 1
      %then %do; %qad_fail(RUN_AND_SPEC_ID_REQUIRED); %goto finish; %end;
  %end;
  %if %length(%superq(outlib))>8 or not %sysfunc(nvalid(%superq(outlib),V7))
    %then %do; %qad_fail(OUTPUT_LIBRARY_REQUIRED); %goto finish; %end;
  %if %sysfunc(libref(&outlib)) ne 0 %then %do;
    %qad_fail(OUTPUT_LIBRARY_REQUIRED); %goto finish;
  %end;
  %let numvars=PersonKey Value Datetime TransDt TimeFromTransfusion PatientAge
      ICU_time RBC_Count Crystalloid_1 Crystalloid_24 Pressors_1 Pressors_24
      Sedatives_1 Sedatives_24;
  %qad_require(ds=&data,
    vars=RBC_EventKey VitalCode PatientSex WardName &numvars,
    types=C C C C N N N N N N N N N N N N N N);
  %if &RBC_QA_ERROR ne NONE %then %goto finish;
  %if %length(%superq(recordings))>0 %then %do;
    %if %upcase(%superq(recording_scope)) ne SOURCE_RECORDS_BEFORE_EVENT_LINKAGE or
        %upcase(%superq(recording_keys_verified)) ne YES
      %then %do; %qad_fail(VERIFIED_PRE_WINDOW_SOURCE_RECORDS_REQUIRED); %goto finish; %end;
    %if %length(%superq(recording_population_id))=0 or %length(%superq(recording_population_id))>64 or
        %sysfunc(prxmatch(/^[A-Za-z0-9_-]+$/,%superq(recording_population_id))) ne 1
      %then %do; %qad_fail(SOURCE_POPULATION_ID_REQUIRED); %goto finish; %end;
    %qad_require(ds=&recordings,
      vars=PersonKey ICUAdmissionKey RecordingSeriesKey SourceRecordKey VitalCode Datetime Value,
      types=N C C C C N N);
    %if &RBC_QA_ERROR ne NONE %then %goto finish;
    %let have_source=1;
  %end;
  %do i=1 %to %sysfunc(countw(&outnames));
    %let name=%scan(&outnames,&i);
    %if %sysfunc(exist(&outlib..&name,DATA)) or %sysfunc(exist(&outlib..&name,VIEW))
      %then %do; %qad_fail(OUTPUT_ALREADY_EXISTS); %goto finish; %end;
  %end;
  proc sql noprint;
    select count(*) into :existing trimmed from dictionary.tables
      where libname='WORK' and substr(upcase(memname),1,5)='_QAD_';
  quit;
  %qad_step(SCRATCH_GUARD);
  %if &RBC_QA_ERROR ne NONE %then %goto finish;
  %if &existing ne 0 %then %do; %qad_fail(SCRATCH_COLLISION); %goto finish; %end;
  %let made=1;
  data work._qad_data; set &data(keep=RBC_EventKey VitalCode PatientSex WardName &numvars); run;
  %qad_step(ANALYSIS_PROJECTION);
  %if &RBC_QA_ERROR ne NONE %then %goto finish;
  proc sql noprint;
    select count(*) into :nbad trimmed from work._qad_data
      where VitalCode not in ('ARTm','ARTs','ARTd','HR','FIO2','SPO2','VE') or missing(VitalCode);
  quit;
  %qad_step(OUTCOME_CODE_CHECK);
  %if &RBC_QA_ERROR ne NONE %then %goto finish;
  %if &nbad>0 %then %do; %qad_fail(UNRECOGNIZED_VITAL_CODE); %goto finish; %end;
  data work._qad_codes;
    length VitalCode $4;
    do OutcomeOrder=1 to 7;
      VitalCode=scan('ARTm ARTs ARTd HR FIO2 SPO2 VE',OutcomeOrder,' ');
      output;
    end;
  run;
  %qad_step(QA_OUTCOME_SEED);
  %if &RBC_QA_ERROR ne NONE %then %goto finish;

  %let covars=PatientAge PatientSex WardName ICU_time RBC_Count
    Crystalloid_1 Crystalloid_24 Pressors_1 Pressors_24 Sedatives_1 Sedatives_24
    TimeFromTransfusion;
  %let ncov=%sysfunc(countw(&covars));
  proc sql noprint;
    create table work._qad_counts as
    select VitalCode, count(*) as NRows,
      count(distinct PersonKey) as NPatients,
      count(distinct RBC_EventKey) as NEvents,
      count(distinct case when not missing(Value) then PersonKey else . end)
        as NPatientsWithValue,
      count(distinct case when not missing(Value) then RBC_EventKey else '' end)
        as NEventsWithValue,
      sum(case when missing(Value) then 1 else 0 end) as NMissingValue,
      sum(case when missing(PersonKey) then 1 else 0 end) as NMissingPersonKey,
      sum(case when missing(RBC_EventKey) then 1 else 0 end) as NMissingEventKey,
      sum(case when missing(Datetime) then 1 else 0 end) as NMissingDatetime,
      sum(case when missing(TransDt) then 1 else 0 end) as NMissingTransDt,
      sum(case when not missing(Value) and Value<0 then 1 else 0 end)
        as NNegativeValueFlag,
      sum(case when VitalCode in ('FIO2','SPO2') and
        not missing(Value) and Value>100 then 1 else 0 end)
        as NOxygenAbove100Flag,
      sum(case when not missing(ICU_time) and ICU_time<0 then 1 else 0 end)
        as NNegativeICUTimeFlag,
      sum(case when not missing(RBC_Count) and RBC_Count<0 then 1 else 0 end)
        as NNegativeRBCCountFlag,
      sum(case when not missing(RBC_Count) and RBC_Count ne floor(RBC_Count)
        then 1 else 0 end) as NNonintegerRBCCountFlag,

      sum(case when not missing(Crystalloid_1) and Crystalloid_1<0 then 1 else 0 end)
        as NNegativeCrystalloid1Flag,
      sum(case when not missing(Crystalloid_24) and Crystalloid_24<0 then 1 else 0 end)
        as NNegativeCrystalloid24Flag,
      sum(case when not missing(Pressors_1) and Pressors_1<0 then 1 else 0 end)
        as NNegativePressors1Flag,
      sum(case when not missing(Pressors_24) and Pressors_24<0 then 1 else 0 end)
        as NNegativePressors24Flag,
      sum(case when not missing(Sedatives_1) and Sedatives_1<0 then 1 else 0 end)
        as NNegativeSedatives1Flag,
      sum(case when not missing(Sedatives_24) and Sedatives_24<0 then 1 else 0 end)
        as NNegativeSedatives24Flag,
      sum(case when cmiss(PersonKey,PatientAge,PatientSex,WardName,ICU_time,
        RBC_Count,TimeFromTransfusion)>0 then 1 else 0 end)
        as NRowsMissingBaseCovariate,
      sum(case when cmiss(PersonKey,PatientAge,PatientSex,WardName,ICU_time,
        RBC_Count,TimeFromTransfusion,Crystalloid_1,Crystalloid_24,Pressors_1,
        Pressors_24,Sedatives_1,Sedatives_24)>0 then 1 else 0 end)
        as NRowsMissingFullCovariate
      %do i=1 %to &ncov;
        %let v=%scan(&covars,&i);
        , sum(case when missing(&v) then 1 else 0 end) as _miss_&v
      %end;
    from work._qad_data group by VitalCode;
  quit;
  %qad_step(QA_COUNTS);
  %if &RBC_QA_ERROR ne NONE %then %goto finish;

  proc sql noprint;
    create table work._qad_outcome as
    select s.OutcomeOrder, s.VitalCode,
      coalesce(c.NRows,0) as NRows,
      coalesce(c.NPatients,0) as NPatients,
      coalesce(c.NEvents,0) as NEvents,
      coalesce(c.NPatientsWithValue,0) as NPatientsWithValue,
      coalesce(c.NEventsWithValue,0) as NEventsWithValue,
      coalesce(c.NMissingValue,0) as NMissingValue,
      coalesce(c.NMissingPersonKey,0) as NMissingPersonKey,
      coalesce(c.NMissingEventKey,0) as NMissingEventKey,
      coalesce(c.NMissingDatetime,0) as NMissingDatetime,
      coalesce(c.NMissingTransDt,0) as NMissingTransDt,
      coalesce(c.NNegativeValueFlag,0) as NNegativeValueFlag,
      case when "%upcase(&oxygen_units)"="PERCENT" then coalesce(c.NOxygenAbove100Flag,0)
        else . end as NOxygenAbove100Flag,
      coalesce(c.NNegativeICUTimeFlag,0) as NNegativeICUTimeFlag,
      coalesce(c.NNegativeRBCCountFlag,0) as NNegativeRBCCountFlag,
      coalesce(c.NNonintegerRBCCountFlag,0) as NNonintegerRBCCountFlag,
      coalesce(c.NNegativeCrystalloid1Flag,0) as NNegativeCrystalloid1Flag,
      coalesce(c.NNegativeCrystalloid24Flag,0) as NNegativeCrystalloid24Flag,
      coalesce(c.NNegativePressors1Flag,0) as NNegativePressors1Flag,
      coalesce(c.NNegativePressors24Flag,0) as NNegativePressors24Flag,
      coalesce(c.NNegativeSedatives1Flag,0) as NNegativeSedatives1Flag,
      coalesce(c.NNegativeSedatives24Flag,0) as NNegativeSedatives24Flag,
      coalesce(c.NRowsMissingBaseCovariate,0) as NRowsMissingBaseCovariate,
      coalesce(c.NRowsMissingFullCovariate,0) as NRowsMissingFullCovariate
      %do i=1 %to &ncov;
        %let v=%scan(&covars,&i);
        , coalesce(c._miss_&v,0) as _miss_&v
      %end;
    from work._qad_codes as s left join work._qad_counts as c
      on s.VitalCode=c.VitalCode order by s.OutcomeOrder;
  quit;
  %qad_step(QA_ALL_OUTCOME_COUNTS);
  %if &RBC_QA_ERROR ne NONE %then %goto finish;

  data work._qad_missing;
    length Variable $32 MissingDefinition $80;
    set work._qad_outcome;
    array missed[*] _miss_:;
    do _q=1 to dim(missed);
      Variable=substr(vname(missed[_q]),7);
      NMissing=missed[_q]; NNonmissing=NRows-NMissing;
      MissingDefinition='MISSING(): includes ordinary and special numeric missing';
      output;
    end;
    keep OutcomeOrder VitalCode Variable NRows NMissing NNonmissing
      MissingDefinition;
  run;
  %qad_step(QA_COVARIATE_MISSING);
  %if &RBC_QA_ERROR ne NONE %then %goto finish;

  proc means data=work._qad_data nway noprint qmethod=OS qntldef=5;
    class VitalCode;
    var Value;
    output out=work._qad_valraw(drop=_TYPE_ _FREQ_)
      n=NValues p5=ValueP5 p25=ValueP25 p50=ValueP50
      p75=ValueP75 p95=ValueP95;
  run;
  %qad_step(QA_VALUE_QUANTILES);
  %if &RBC_QA_ERROR ne NONE %then %goto finish;
  proc sql noprint;
    create table work._qad_values as
    select s.OutcomeOrder,s.VitalCode,coalesce(v.NValues,0) as NValues,
      v.ValueP5,v.ValueP25,v.ValueP50,v.ValueP75,v.ValueP95,
      'ORDER_STATISTICS_QNTLDEF5' as QuantileMethod length=32
    from work._qad_codes as s left join work._qad_valraw as v
      on s.VitalCode=v.VitalCode order by s.OutcomeOrder;
  quit;
  %qad_step(QA_VALUE_QUANTILES_COMPLETE);
  %if &RBC_QA_ERROR ne NONE %then %goto finish;

  proc sql noprint;
    create table work._qad_aduptmp as
      select VitalCode,PersonKey,RBC_EventKey,Datetime,count(*) as GroupRows,
        (missing(PersonKey) or missing(RBC_EventKey) or missing(Datetime)) as KeyMissing
      from work._qad_data group by VitalCode,PersonKey,RBC_EventKey,Datetime;
    create table work._qad_adupcounts as select VitalCode,
      sum(case when KeyMissing=0 and GroupRows>1 then 1 else 0 end) as NDuplicateGroups,
      sum(case when KeyMissing=0 and GroupRows>1 then GroupRows else 0 end) as NRowsInDuplicateGroups,
      sum(case when KeyMissing=0 and GroupRows>1 then GroupRows-1 else 0 end) as NExtraDuplicateRows,
      sum(case when KeyMissing=1 then GroupRows else 0 end) as NMissingDuplicateKeyRows
      from work._qad_aduptmp group by VitalCode;
    create table work._qad_duplicates as select s.OutcomeOrder,s.VitalCode,
      coalesce(c.NDuplicateGroups,0) as NDuplicateGroups,
      coalesce(c.NRowsInDuplicateGroups,0) as NRowsInDuplicateGroups,
      coalesce(c.NExtraDuplicateRows,0) as NExtraDuplicateRows,
      coalesce(c.NMissingDuplicateKeyRows,0) as NMissingDuplicateKeyRows,
      'PERSON_EVENT_VITAL_DATETIME' as DuplicateKeyDefinition length=40,
      'NO_ANALYSIS_RECORDS_REMOVED' as ActionTaken length=40
      from work._qad_codes s left join work._qad_adupcounts c
        on s.VitalCode=c.VitalCode order by s.OutcomeOrder;
  quit;
  %qad_step(ANALYSIS_DUPLICATES);
  %if &RBC_QA_ERROR ne NONE %then %goto finish;

  %if &have_source=1 %then %do;
    data work._qad_source;
      set &recordings(keep=PersonKey ICUAdmissionKey RecordingSeriesKey SourceRecordKey VitalCode Datetime Value);
    run;
    %qad_step(SOURCE_PROJECTION);
    %if &RBC_QA_ERROR ne NONE %then %goto finish;
    proc sql noprint;
      select count(*) into :nbad trimmed from work._qad_source
        where missing(PersonKey) or missing(ICUAdmissionKey) or missing(RecordingSeriesKey)
          or missing(SourceRecordKey) or missing(VitalCode)
          or VitalCode not in ('ARTm','ARTs','ARTd','HR','FIO2','SPO2','VE');
      create table work._qad_sdupkeys as select SourceRecordKey from work._qad_source
        group by SourceRecordKey having count(*) ne 1;
      create table work._qad_sadm as select distinct ICUAdmissionKey,PersonKey from work._qad_source;
      create table work._qad_sadmdup as select ICUAdmissionKey from work._qad_sadm
        group by ICUAdmissionKey having count(*) ne 1;
      select count(*)+&nbad into :nbad trimmed from work._qad_sdupkeys;
      select count(*)+&nbad into :nbad trimmed from work._qad_sadmdup;
    quit;
    %qad_step(SOURCE_KEY_VALIDATION);
    %if &RBC_QA_ERROR ne NONE %then %goto finish;
    %if &nbad>0 %then %do; %qad_fail(SOURCE_RECORD_IDENTITY_OR_MAPPING_INVALID); %goto finish; %end;
    proc sort data=work._qad_source out=work._qad_ssort;
      by PersonKey ICUAdmissionKey RecordingSeriesKey VitalCode Datetime;
    run;
    %qad_step(SOURCE_INTERVAL_SORT);
    %if &RBC_QA_ERROR ne NONE %then %goto finish;
    data work._qad_spositions(keep=VitalCode GroupRows IntervalSeconds PairStatus);
      set work._qad_ssort;
      by PersonKey ICUAdmissionKey RecordingSeriesKey VitalCode Datetime;
      length PairStatus $20;
      retain PreviousTime GroupRows;
      if first.VitalCode then PreviousTime=.;
      if first.Datetime then GroupRows=0;
      GroupRows+1;
      if last.Datetime then do;
        IntervalSeconds=.;
        if missing(Datetime) then PairStatus='MISSING_TIMESTAMP';
        else if missing(PreviousTime) then PairStatus='SERIES_START';
        else do;
          IntervalSeconds=Datetime-PreviousTime;
          if IntervalSeconds>0 then PairStatus='POSITIVE';
          else PairStatus='NONPOSITIVE';
        end;
        output;
        if not missing(Datetime) then PreviousTime=Datetime;
      end;
    run;
    %qad_step(SOURCE_UNIQUE_TIMESTAMPS);
    %if &RBC_QA_ERROR ne NONE %then %goto finish;
    proc sql noprint;
      create table work._qad_scount as select VitalCode,
        sum(GroupRows) as NUniqueMeasurements,
        sum(PairStatus ne 'MISSING_TIMESTAMP') as NUniqueTimestamps,
        sum(PairStatus='POSITIVE') as NIntervals,
        sum(PairStatus='NONPOSITIVE') as NNonpositiveIntervals,
        sum(PairStatus='SERIES_START') as NSeriesStarts,
        sum(case when PairStatus='MISSING_TIMESTAMP' then GroupRows else 0 end) as NMissingDatetime,
        sum(PairStatus ne 'MISSING_TIMESTAMP' and GroupRows>1) as NTimestampTieGroups,
        sum(case when PairStatus ne 'MISSING_TIMESTAMP' and GroupRows>1 then GroupRows else 0 end) as NRecordsAtTiedTimestamps
        from work._qad_spositions group by VitalCode;
    quit;
    %qad_step(SOURCE_INTERVAL_COUNTS);
    %if &RBC_QA_ERROR ne NONE %then %goto finish;
    proc means data=work._qad_spositions nway noprint qmethod=OS qntldef=5;
      where IntervalSeconds>0;
      class VitalCode; var IntervalSeconds;
      output out=work._qad_squant(drop=_TYPE_ _FREQ_) p5=IntervalP5Seconds
        p25=Q1IntervalSeconds p50=MedianIntervalSeconds p75=Q3IntervalSeconds p95=IntervalP95Seconds;
    run;
    proc means data=work._qad_source nway noprint qmethod=OS qntldef=5;
      class VitalCode; var Value;
      output out=work._qad_svraw(drop=_TYPE_ _FREQ_) n=NValues
        p5=ValueP5 p25=ValueP25 p50=ValueP50 p75=ValueP75 p95=ValueP95;
    run;
    %qad_step(SOURCE_QUANTILES);
    %if &RBC_QA_ERROR ne NONE %then %goto finish;
    proc sql noprint;
      create table work._qad_intervals as select s.OutcomeOrder,s.VitalCode,
        coalesce(c.NUniqueMeasurements,0) as NUniqueMeasurements,
        coalesce(c.NUniqueTimestamps,0) as NUniqueTimestamps,
        coalesce(c.NIntervals,0) as NIntervals,
        coalesce(c.NNonpositiveIntervals,0) as NNonpositiveIntervals,
        coalesce(c.NSeriesStarts,0) as NSeriesStarts,
        coalesce(c.NMissingDatetime,0) as NMissingDatetime,
        coalesce(c.NTimestampTieGroups,0) as NTimestampTieGroups,
        coalesce(c.NRecordsAtTiedTimestamps,0) as NRecordsAtTiedTimestamps,
        q.IntervalP5Seconds,q.Q1IntervalSeconds,q.MedianIntervalSeconds,q.Q3IntervalSeconds,q.IntervalP95Seconds,
        'SUPPLIED_SOURCE_RECORDS_ONLY' as CoverageStatus length=40
        from work._qad_codes s left join work._qad_scount c on s.VitalCode=c.VitalCode
          left join work._qad_squant q on s.VitalCode=q.VitalCode order by s.OutcomeOrder;
      create table work._qad_srcvalues as select s.OutcomeOrder,s.VitalCode,
        coalesce(v.NValues,0) as NValues,v.ValueP5,v.ValueP25,v.ValueP50,v.ValueP75,v.ValueP95,
        'SUPPLIED_SOURCE_RECORDS_ONLY' as CoverageStatus length=40
        from work._qad_codes s left join work._qad_svraw v on s.VitalCode=v.VitalCode
        order by s.OutcomeOrder;
    quit;
    %qad_step(SOURCE_COMPLETE_OUTPUTS);
    %if &RBC_QA_ERROR ne NONE %then %goto finish;
  %end;
  %else %do;
    data work._qad_intervals;
      set work._qad_codes;
      length CoverageStatus $40;
      array Unavailable[*] NUniqueMeasurements NUniqueTimestamps NIntervals NNonpositiveIntervals
        NSeriesStarts NMissingDatetime NTimestampTieGroups NRecordsAtTiedTimestamps
        IntervalP5Seconds Q1IntervalSeconds MedianIntervalSeconds Q3IntervalSeconds IntervalP95Seconds;
      do i=1 to dim(Unavailable); Unavailable[i]=.; end;
      CoverageStatus='NOT_AVAILABLE'; drop i;
    run;
    data work._qad_srcvalues;
      set work._qad_codes;
      length CoverageStatus $40;
      NValues=.; ValueP5=.; ValueP25=.; ValueP50=.; ValueP75=.; ValueP95=.;
      CoverageStatus='NOT_AVAILABLE';
    run;
    %qad_step(SOURCE_UNAVAILABLE);
    %if &RBC_QA_ERROR ne NONE %then %goto finish;
  %end;
  data work._qad_intervals;
    set work._qad_intervals;
    length DefinitionId SourceGroup GroupingDefinition QuantilePopulation $64;
    DefinitionId='UNIQUE_TIMESTAMP_GAPS_PRE_WINDOW'; SourceGroup='ALL_SUPPLIED_SERIES_POOLED';
    GroupingDefinition='WITHIN_PERSON_ADMISSION_SERIES_OUTCOME';
    QuantilePopulation='POSITIVE_ADJACENT_UNIQUE_TIMESTAMP_GAPS';
  run;
  data work._qad_srcvalues;
    set work._qad_srcvalues;
    length QuantileMethod ValuePopulation $64;
    QuantileMethod='ORDER_STATISTICS_QNTLDEF5'; ValuePopulation='VERIFIED_PRE_WINDOW_SOURCE_RECORDS';
  run;
  data work._qad_values;
    set work._qad_values;
    length ValuePopulation $64;
    ValuePopulation='PREPARED_ANALYSIS_ROWS_WITH_WINDOW_REUSE';
  run;
  data work._qad_status;
    length Field Status $40 Interpretation $160 ActionTaken $40;
    ActionTaken='NONE_DIAGNOSTICS_ONLY';
    Field='SOURCE_ARTIFACT_FLAGS'; Status='NOT_AVAILABLE_IN_INTERFACE';
    Interpretation='Source/device validity flags are not part of this canonical input contract.'; output;
    Field='APPROVED_ARTIFACT_RULE'; Status='NOT_IMPLEMENTED_HERE';
    Interpretation='No artifact exclusions or clinical plausibility thresholds are selected here.'; output;
    Field='VALUE_RANGE_FLAGS'; Status='DIAGNOSTIC_ONLY';
    Interpretation='Negative values are flags only; input is unchanged.'; output;
    Field='OXYGEN_UNIT_DEPENDENT_FLAGS';
    %if %upcase(%superq(oxygen_units))=PERCENT %then %do;
      Status='DIAGNOSTIC_ONLY'; Interpretation='Supplied oxygen percent scale; above-100 counts are flags only.';
    %end;
    %else %do;
      Status='UNAVAILABLE_UNVERIFIED_UNITS';
      Interpretation='Source oxygen scale is unverified; unit-dependent flag counts are missing; no conversion.';
    %end;
    output;
    Field='SOURCE_RECORDING_FREQUENCY';
    %if &have_source=1 %then %do;
      Status='SUPPLIED_SOURCE_RECORDS_ONLY';
      Interpretation='Unique timestamp gaps precede window reuse and stay within person/admission/series/outcome; source completeness remains unproven.';
    %end;
    %else %do;
      Status='NOT_AVAILABLE';
      Interpretation='No authoritative pre-window source-record interface supplied; prepared-row gaps cannot establish recording frequency.';
    %end;
    output;
    Field='DUPLICATE_KEY_GROUPS'; Status='DIAGNOSTIC_ONLY';
    Interpretation='Prepared event/outcome/timestamp ties are counted; no analysis records are removed or called proven source duplicates.'; output;
    Field='MEDICATION_MISSING'; Status='PRESERVED_IN_COUNTS';
    Interpretation='Incoming missing numeric medication fields remain missing, never recoded to zero here.'; output;
    Field='MEDICATION_NEGATIVE_VALUE_FLAGS'; Status='DIAGNOSTIC_ONLY';
    Interpretation='Negative inherited medication values are counted per prepared analysis row against NRows; missing and special missing are excluded; no recode or exclusion.'; output;
    Field='UPSTREAM_MEDICATION_ZERO_MEANING'; Status='UNRESOLVED';
    Interpretation='This interface cannot recover missing or unmatched records already coalesced upstream; incoming zero does not establish no administration.'; output;
    Field='FIT_COMPLETE_CASE_COUNTS'; Status='NOT_ESTABLISHED_HERE';
    Interpretation='The separate fit registry must report actual rows and people used by each model.'; output;
    Field='EXPORT_DISCLOSURE_APPROVAL'; Status='NOT_APPROVED';
    Interpretation='All diagnostics remain private and unreviewed; no outputs are automatically published.'; output;
  run;
  %qad_step(PROCESSING_STATUS);
  %if &RBC_QA_ERROR ne NONE %then %goto finish;
  %let published=1;
  %do i=1 %to %sysfunc(countw(&outnames));
    %let name=%scan(&outnames,&i);
    data &outlib..&name;
      length RunId AnalysisSpecId SourcePopulationId $64 CohortMode $24
        PopulationId AnalysisPopulationId $32 DisclosureStatus $24;
      %if &i ne 6 %then %do; length Outcome $8; %end;
      set work.%scan(&stages,&i);
      %if &i ne 6 %then %do;
        if VitalCode='SPO2' then Outcome='SpO2'; else Outcome=VitalCode;
      %end;
      AnalysisPopulationId=symget('population_id');
      %if &have_source=1 %then %do; SourcePopulationId=symget('recording_population_id'); %end;
      %else %do; SourcePopulationId='NOT_AVAILABLE'; %end;
      RunId=symget('run_id'); AnalysisSpecId=symget('analysis_spec_id');
      CohortMode=symget('cohort_mode'); PopulationId=symget('population_id');
      DisclosureStatus='PRIVATE_UNREVIEWED'; format _numeric_ best32.;
    run;
    %qad_step(OUTPUT_WRITE);
    %if &RBC_QA_ERROR ne NONE %then %goto finish;
  %end;
  %let RBC_QA_OK=1;
%finish:
  %if &made=1 %then %do;
    proc datasets library=work nolist; delete &scratchnames; quit;
    %if &syserr>4 or &syscc>4 %then %do;
      %let RBC_QA_OK=0;
      %if &RBC_QA_ERROR=NONE %then %qad_fail(SCRATCH_CLEANUP_FAILED);
    %end;
  %end;
  %if &RBC_QA_OK ne 1 and &published=1 %then %do;
    proc datasets library=&outlib nolist; delete &outnames; quit;
    %do i=1 %to %sysfunc(countw(&outnames));
      %if %sysfunc(exist(&outlib..%scan(&outnames,&i),DATA)) or
          %sysfunc(exist(&outlib..%scan(&outnames,&i),VIEW))
        %then %qad_fail(OUTPUT_ROLLBACK_FAILED);
    %end;
  %end;
  %if &RBC_QA_OK ne 1 and %upcase(%superq(on_error)) ne RETURN %then %abort cancel;
%mend;

%macro rdd_fail(code);
  %let RBC_DESC_OK=0;
  %let RBC_DESC_ERROR=&code;
  %put NOTE: RBC_DESC_REJECTED &code;
%mend;
%macro rdd_step(stage);
  %if &syserr>4 or &syscc>4 %then %rdd_fail(STEP_FAILED_&stage);
%mend;
%macro rdd_require(ds=,vars=,types=);
  %local lib mem h i pos actual rc;
  %if %sysfunc(countc(%superq(ds),.)) ne 1 %then %do;
    %rdd_fail(SIMPLE_TWO_LEVEL_DATA_NAME_REQUIRED); %return;
  %end;
  %let lib=%qscan(%superq(ds),1,.); %let mem=%qscan(%superq(ds),2,.);
  %if %length(%superq(lib))>8 or %length(%superq(mem))>32 or
      not %sysfunc(nvalid(%superq(lib),V7)) or
      not %sysfunc(nvalid(%superq(mem),V7)) %then %do;
    %rdd_fail(SIMPLE_TWO_LEVEL_DATA_NAME_REQUIRED); %return;
  %end;
  %if not %sysfunc(exist(&ds,DATA)) %then %do;
    %rdd_fail(INPUT_DATA_TABLE_REQUIRED); %return;
  %end;
  %let h=%sysfunc(open(&ds,i));
  %if &h=0 %then %do; %rdd_fail(INPUT_METADATA_UNAVAILABLE); %return; %end;
  %do i=1 %to %sysfunc(countw(&vars));
    %let pos=%sysfunc(varnum(&h,%scan(&vars,&i)));
    %if &pos=0 %then %do;
      %let rc=%sysfunc(close(&h)); %rdd_fail(REQUIRED_COLUMN_ABSENT); %return;
    %end;
    %let actual=%sysfunc(vartype(&h,&pos));
    %if &actual ne %scan(&types,&i) %then %do;
      %let rc=%sysfunc(close(&h)); %rdd_fail(REQUIRED_COLUMN_TYPE_MISMATCH); %return;
    %end;
    %if &actual=C %then %do;
      %if %sysfunc(varlen(&h,&pos))>256 %then %do;
        %let rc=%sysfunc(close(&h)); %rdd_fail(CHARACTER_FIELD_TOO_LONG); %return;
      %end;
    %end;
  %end;
  %let rc=%sysfunc(close(&h));
%mend;

%macro rbc_descriptive_tables(events=,units=,age_bands=,outlib=,
    run_id=,analysis_spec_id=,cohort_mode=,population_id=,
    mapping_verified=,unit_scope=,anchor_policy=,tie_policy=,
    include_saps=NO,on_error=ABORT);
  %global RBC_DESC_OK RBC_DESC_ERROR;
  %local outputs stages scratch i name existing bad n_events n_units n_people
         made published saps_vars saps_types idvar rdd_saps_missing rdd_saps_invalid;
  %let RBC_DESC_OK=0; %let RBC_DESC_ERROR=NONE; %let made=0; %let published=0;
  %let outputs=rdd_cohort_counts rdd_patient_sex rdd_patient_age rdd_patient_age_groups
      rdd_patient_ward rdd_patient_saps rdd_unit_categories rdd_units_per_person
      rdd_anchor_audit rdd_manifest;
  %let stages=_rdd_counts _rdd_sex _rdd_age _rdd_agegroups _rdd_wards _rdd_saps
      _rdd_unitcats _rdd_updist _rdd_audit _rdd_meta;
  %let scratch=_rdd_events _rdd_units _rdd_edup _rdd_udup _rdd_adm _rdd_adup
      _rdd_uk _rdd_eu _rdd_first _rdd_anchor _rdd_ties _rdd_bands _rdd_bcheck
      _rdd_badband _rdd_categories _rdd_catden _rdd_personunits _rdd_variation
      &stages;
  %if &syscc>4 %then %do; %rdd_fail(FRESH_SAS_SESSION_REQUIRED); %goto finish; %end;
  %if %upcase(%superq(on_error)) ne ABORT and %upcase(%superq(on_error)) ne RETURN
    %then %do; %rdd_fail(ERROR_POLICY_REQUIRED); %goto finish; %end;
  %if %upcase(%superq(mapping_verified)) ne YES or
      %upcase(%superq(unit_scope)) ne ELIGIBLE_INDEX_EVENT_UNITS or
      %upcase(%superq(anchor_policy)) ne FIRST_ELIGIBLE_EVENT or
      %upcase(%superq(tie_policy)) ne REQUIRE_IDENTICAL_DESCRIPTORS
    %then %do; %rdd_fail(EXPLICIT_CANONICAL_AND_ANCHOR_CONTRACT_REQUIRED); %goto finish; %end;
  %if %upcase(%superq(include_saps)) ne YES and %upcase(%superq(include_saps)) ne NO
    %then %do; %rdd_fail(SAPS_OPTION_REQUIRED); %goto finish; %end;
  %if %superq(cohort_mode) ne development_sample and %superq(cohort_mode) ne full_cohort
    %then %do; %rdd_fail(COHORT_MODE_REQUIRED); %goto finish; %end;
  %if %superq(population_id) ne PRIMARY and %superq(population_id) ne FIRST_EVENT and
      %superq(population_id) ne NO_FOLLOWING_UNIT_12H
    %then %do; %rdd_fail(POPULATION_ID_REQUIRED); %goto finish; %end;
  %do i=1 %to 2;
    %let idvar=%scan(run_id analysis_spec_id,&i);
    %if %length(%superq(&idvar))=0 or %length(%superq(&idvar))>64 or
        %sysfunc(prxmatch(/^[A-Za-z0-9_-]+$/,%superq(&idvar))) ne 1
      %then %do; %rdd_fail(RUN_AND_SPEC_ID_REQUIRED); %goto finish; %end;
  %end;
  %if %length(%superq(outlib))>8 or not %sysfunc(nvalid(%superq(outlib),V7))
    %then %do; %rdd_fail(OUTPUT_LIBRARY_REQUIRED); %goto finish; %end;
  %if %sysfunc(libref(&outlib)) ne 0 %then %do;
    %rdd_fail(OUTPUT_LIBRARY_REQUIRED); %goto finish;
  %end;
  %if not %sysmacexist(rbc_derive_category_fields) %then %do;
    %rdd_fail(SHARED_CATEGORY_MODULE_REQUIRED); %goto finish;
  %end;
  %let saps_vars=; %let saps_types=;
  %if %upcase(&include_saps)=YES %then %do;
    %let saps_vars=SAPS3 SAPS3_Status; %let saps_types=N C;
  %end;
  %rdd_require(ds=&events,
    vars=PersonKey RBC_EventKey ICUAdmissionKey TransDt PatientAge PatientSex WardCode AdmissionTime DischargeTime &saps_vars,
    types=N C C N N C C N N &saps_types);
  %if &RBC_DESC_ERROR ne NONE %then %goto finish;
  %rdd_require(ds=&units,
    vars=PersonKey RBC_EventKey ICUAdmissionKey TransDt RBC_UnitKey DonorHb Storage DonorSex DonorParity wdy_donation,
    types=N C C N C N N N N N);
  %if &RBC_DESC_ERROR ne NONE %then %goto finish;
  %rdd_require(ds=&age_bands,vars=BandOrder BandCode BandLabel LowerBound UpperBound,
    types=N C C N N);
  %if &RBC_DESC_ERROR ne NONE %then %goto finish;
  %do i=1 %to %sysfunc(countw(&outputs));
    %let name=%scan(&outputs,&i);
    %if %sysfunc(exist(&outlib..&name,DATA)) or %sysfunc(exist(&outlib..&name,VIEW))
      %then %do; %rdd_fail(OUTPUT_ALREADY_EXISTS); %goto finish; %end;
  %end;
  proc sql noprint;
    select count(*) into :existing trimmed from dictionary.tables
      where libname='WORK' and substr(upcase(memname),1,5)='_RDD_';
  quit;
  %rdd_step(SCRATCH_GUARD);
  %if &RBC_DESC_ERROR ne NONE %then %goto finish;
  %if &existing ne 0 %then %do; %rdd_fail(SCRATCH_COLLISION); %goto finish; %end;
  %let made=1;
  data work._rdd_events;
    set &events(keep=PersonKey RBC_EventKey ICUAdmissionKey TransDt PatientAge
      PatientSex WardCode AdmissionTime DischargeTime &saps_vars);
    %if %upcase(&include_saps)=NO %then %do;
      length SAPS3_Status $16; SAPS3=.; SAPS3_Status='NOT_REQUESTED';
    %end;
  run;
  data work._rdd_units;
    set &units(keep=PersonKey RBC_EventKey ICUAdmissionKey TransDt RBC_UnitKey
      DonorHb Storage DonorSex DonorParity wdy_donation);
  run;
  proc sort data=&age_bands(keep=BandOrder BandCode BandLabel LowerBound UpperBound)
      out=work._rdd_bands; by BandOrder; run;
  %rdd_step(PROJECTIONS);
  %if &RBC_DESC_ERROR ne NONE %then %goto finish;
  proc sql noprint;
    select count(*) into :n_events trimmed from work._rdd_events;
    select count(*) into :n_units trimmed from work._rdd_units;
    select count(*) into :bad trimmed from work._rdd_events
      where missing(PersonKey) or missing(RBC_EventKey) or missing(ICUAdmissionKey)
        or missing(TransDt) or missing(AdmissionTime) or missing(DischargeTime)
        or AdmissionTime>TransDt or TransDt>DischargeTime;
  quit;
  %rdd_step(EVENT_KEY_CHECK);
  %if &RBC_DESC_ERROR ne NONE %then %goto finish;
  %if &n_events=0 or &n_units=0 %then %do; %rdd_fail(NONEMPTY_CANONICAL_INPUTS_REQUIRED); %goto finish; %end;
  %if &bad ne 0 %then %do; %rdd_fail(EVENT_KEYS_OR_ADMISSION_BOUNDS_INVALID); %goto finish; %end;
  proc sql noprint;
    select count(*) into :bad trimmed from work._rdd_units
      where missing(PersonKey) or missing(RBC_EventKey) or missing(ICUAdmissionKey)
        or missing(TransDt) or missing(RBC_UnitKey);
    create table work._rdd_edup as select RBC_EventKey from work._rdd_events
      group by RBC_EventKey having count(*) ne 1;
    create table work._rdd_udup as select RBC_UnitKey from work._rdd_units
      group by RBC_UnitKey having count(*) ne 1;
    create table work._rdd_adm as select distinct ICUAdmissionKey,PersonKey,
      AdmissionTime,DischargeTime from work._rdd_events;
    create table work._rdd_adup as select ICUAdmissionKey from work._rdd_adm
      group by ICUAdmissionKey having count(*) ne 1;
  quit;
  %rdd_step(IDENTITY_CHECKS);
  %if &RBC_DESC_ERROR ne NONE %then %goto finish;
  %if &bad ne 0 %then %do; %rdd_fail(UNIT_KEYS_INCOMPLETE); %goto finish; %end;
  proc sql noprint;
    select (select count(*) from work._rdd_edup)+(select count(*) from work._rdd_udup)
      +(select count(*) from work._rdd_adup) into :bad trimmed from work._rdd_events(obs=1);
  quit;
  %rdd_step(IDENTITY_COUNTS);
  %if &RBC_DESC_ERROR ne NONE %then %goto finish;
  %if &bad ne 0 %then %do; %rdd_fail(DUPLICATE_OR_CONFLICTING_CANONICAL_KEY); %goto finish; %end;
  proc sql noprint;
    create table work._rdd_uk as select u.RBC_UnitKey,count(e.RBC_EventKey) as N
      from work._rdd_units u left join work._rdd_events e
      on u.RBC_EventKey=e.RBC_EventKey and u.PersonKey=e.PersonKey
        and u.ICUAdmissionKey=e.ICUAdmissionKey and u.TransDt=e.TransDt
      group by u.RBC_UnitKey;
    create table work._rdd_eu as select e.RBC_EventKey,count(u.RBC_UnitKey) as N
      from work._rdd_events e left join work._rdd_units u
      on e.RBC_EventKey=u.RBC_EventKey group by e.RBC_EventKey;
    select count(*) into :bad trimmed from work._rdd_uk where N ne 1;
    select count(*)+&bad into :bad trimmed from work._rdd_eu where N<1;
  quit;
  %rdd_step(EVENT_UNIT_LINKAGE);
  %if &RBC_DESC_ERROR ne NONE %then %goto finish;
  %if &bad ne 0 %then %do; %rdd_fail(CANONICAL_EVENT_UNIT_LINKAGE_INVALID); %goto finish; %end;
  %if %upcase(&include_saps)=YES %then %do;
    proc sql noprint;
      select count(*) into :bad trimmed from work._rdd_events
        where SAPS3_Status not in ('VALID','MISSING','INVALID')
          or (SAPS3_Status='VALID' and missing(SAPS3))
          or (SAPS3_Status ne 'VALID' and not missing(SAPS3));
    quit;
    %rdd_step(SAPS_CONVERSION_CONTRACT);
    %if &RBC_DESC_ERROR ne NONE %then %goto finish;
    %if &bad ne 0 %then %do; %rdd_fail(SAPS_CONVERSION_STATUS_INCONSISTENT); %goto finish; %end;
  %end;
  %let bad=0;
  data work._rdd_bcheck;
    set work._rdd_bands end=last;
    retain PreviousUpper PreviousOrder;
    Invalid=(missing(BandOrder) or missing(BandCode) or missing(BandLabel)
      or lengthn(BandCode)>32 or lengthn(BandLabel)>64
      or upcase(BandCode)='_MISSING_');
    if _n_=1 and not missing(LowerBound) then Invalid=1;
    if _n_>1 and (missing(LowerBound) or LowerBound ne PreviousUpper
      or BandOrder<=PreviousOrder) then Invalid=1;
    if not last and missing(UpperBound) then Invalid=1;
    if last and not missing(UpperBound) then Invalid=1;
    if not missing(LowerBound) and not missing(UpperBound)
      and LowerBound>=UpperBound then Invalid=1;
    if Invalid then call symputx('bad',1,'L');
    PreviousUpper=UpperBound; PreviousOrder=BandOrder;
  run;
  proc sql noprint;
    select count(*) into :existing trimmed from work._rdd_bands;
    create table work._rdd_badband as select BandCode from work._rdd_bands
      group by BandCode having count(*) ne 1;
    select count(*)+&bad into :bad trimmed from work._rdd_badband;
  quit;
  %rdd_step(AGE_BAND_CONFIGURATION);
  %if &RBC_DESC_ERROR ne NONE %then %goto finish;
  %if &existing=0 or &bad ne 0 %then %do; %rdd_fail(EXHAUSTIVE_AGE_BAND_CONFIG_REQUIRED); %goto finish; %end;
  proc sql;
    create table work._rdd_first as select PersonKey,min(TransDt) as FirstTime,
      count(*) as NEvents from work._rdd_events group by PersonKey;
    create table work._rdd_anchor as select distinct e.PersonKey,e.TransDt,e.PatientAge,
      e.PatientSex,e.WardCode,e.ICUAdmissionKey,e.AdmissionTime,e.DischargeTime,
      e.SAPS3,e.SAPS3_Status from work._rdd_events e inner join work._rdd_first f
      on e.PersonKey=f.PersonKey and e.TransDt=f.FirstTime;
    create table work._rdd_ties as select PersonKey from work._rdd_anchor
      group by PersonKey having count(*) ne 1;
  quit;
  %rdd_step(FIRST_EVENT_ANCHOR);
  %if &RBC_DESC_ERROR ne NONE %then %goto finish;
  proc sql noprint;
    select count(*) into :bad trimmed from work._rdd_ties;
    select count(*) into :n_people trimmed from work._rdd_anchor;
  quit;
  %rdd_step(ANCHOR_UNIQUENESS);
  %if &RBC_DESC_ERROR ne NONE %then %goto finish;
  %if &bad ne 0 %then %do; %rdd_fail(FIRST_EVENT_DESCRIPTOR_CONFLICT); %goto finish; %end;

  proc sql;
    create table work._rdd_counts as
      select 'PERSONS' as CountingUnit length=24,count(*) as Count,
        'ONE_PERSON_AT_FIRST_ELIGIBLE_EVENT' as CountDefinition length=64 from work._rdd_anchor
      union all select 'ICU_ADMISSIONS',count(distinct ICUAdmissionKey),'CANONICAL_ADMISSIONS_IN_SUPPLIED_EVENTS' from work._rdd_events
      union all select 'INDEX_EVENTS',count(*),'SUPPLIED_ELIGIBLE_INDEX_EVENTS' from work._rdd_events
      union all select 'LINKED_PHYSICAL_UNITS',count(*),'PHYSICAL_UNITS_LINKED_TO_SUPPLIED_ELIGIBLE_INDEX_EVENTS' from work._rdd_units;
    create table work._rdd_sex as select
      case when missing(PatientSex) then 'MISSING' when PatientSex in ('F','M') then PatientSex
        else 'INVALID' end as Patient_Sex length=8,count(*) as No_of_Patients,
        &n_people as Denominator,100*count(*)/&n_people as Percent
      from work._rdd_anchor group by calculated Patient_Sex;
    create table work._rdd_wards as select WardCode,
      case when missing(WardCode) then 'MISSING' else 'AVAILABLE' end as Status length=16,
      count(*) as No_of_Patients,&n_people as Denominator
      from work._rdd_anchor group by WardCode,calculated Status;
    create table work._rdd_agegroups as select b.BandOrder,b.BandCode length=32,b.BandLabel length=64,
      count(a.PersonKey) as Count,&n_people as Denominator,
      100*count(a.PersonKey)/&n_people as Percent
      from work._rdd_bands b left join work._rdd_anchor a
      on not missing(a.PatientAge) and (missing(b.LowerBound) or a.PatientAge>=b.LowerBound)
        and (missing(b.UpperBound) or a.PatientAge<b.UpperBound)
      group by b.BandOrder,b.BandCode,b.BandLabel
      union all select ., '_MISSING_', 'Missing age',count(*),&n_people,100*count(*)/&n_people
        from work._rdd_anchor where missing(PatientAge);
    create table work._rdd_personunits as select a.PersonKey,count(u.RBC_UnitKey) as NUnits
      from work._rdd_anchor a left join work._rdd_units u on a.PersonKey=u.PersonKey
      group by a.PersonKey;
    create table work._rdd_updist as select NUnits as Linked_Index_Units,
      count(*) as No_of_Patients,&n_people as Denominator,
      count(*)/&n_people as Relative_Frequency,
      'ELIGIBLE_INDEX_EVENT_UNITS' as UnitScope length=32
      from work._rdd_personunits group by NUnits;
    create table work._rdd_variation as select e.PersonKey,
      count(distinct e.PatientAge)+max(missing(e.PatientAge)) as NAgeProfiles,
      count(distinct e.PatientSex)+max(missing(e.PatientSex)) as NSexProfiles,
      sum(e.TransDt=f.FirstTime) as NEarliestEvents
      from work._rdd_events e inner join work._rdd_first f on e.PersonKey=f.PersonKey
      group by e.PersonKey;
    create table work._rdd_audit as select
      count(*) as NPersons,
      sum(NAgeProfiles>1) as PersonsWithChangingAge,
      sum(NSexProfiles>1) as PersonsWithChangingSex,
      sum(NEarliestEvents>1) as PersonsWithEquivalentFirstTies
      from work._rdd_variation;
  quit;
  %rdd_step(PATIENT_DESCRIPTORS);
  %if &RBC_DESC_ERROR ne NONE %then %goto finish;
  proc means data=work._rdd_anchor noprint;
    var PatientAge;
    output out=work._rdd_age(drop=_TYPE_ _FREQ_) n=N_Age nmiss=N_Missing_Age
      mean=Mean_Age std=SD_Age median=Median_Age q1=Q1_Age q3=Q3_Age
      min=Min_Age max=Max_Age;
  run;
  data work._rdd_age; set work._rdd_age; NPersons=&n_people; run;
  proc means data=work._rdd_anchor noprint;
    var SAPS3;
    output out=work._rdd_saps(drop=_TYPE_ _FREQ_) n=NAvailable
      mean=Mean std=SD median=Median q1=Q1 q3=Q3;
  run;
  proc sql noprint;
    select sum(SAPS3_Status='MISSING'),sum(SAPS3_Status='INVALID')
      into :rdd_saps_missing trimmed,:rdd_saps_invalid trimmed from work._rdd_anchor;
  quit;
  data work._rdd_saps;
    set work._rdd_saps;
    length Status $16;
    NPersons=&n_people; NMissing=&rdd_saps_missing; NInvalid=&rdd_saps_invalid;
    %if %upcase(&include_saps)=YES %then %do; Status='COMPUTED'; NNotRequested=0; %end;
    %else %do; Status='NOT_REQUESTED'; NNotRequested=&n_people; %end;
  run;
  %rdd_step(CONTINUOUS_DESCRIPTORS);
  %if &RBC_DESC_ERROR ne NONE %then %goto finish;

  data work._rdd_categories;
    set work._rdd_units;
    %rbc_derive_category_fields;
    length Factor $16 CategoryCode $32 CategoryLabel $64 Status $16;
    Eligible=1;
    Factor='DonorHb';
    if missing(DonorHb_Cat) then do; CategoryCode='HB_MISSING'; Status='MISSING'; end;
    else do; CategoryCode=cats('HB_',put(DonorHb_Cat,1.)); Status='VALID'; end;
    CategoryLabel=RBC_Hb_Label; output;
    Factor='Storage';
    if RBC_Storage_Status='missing' then do; CategoryCode='STORAGE_MISSING'; Status='MISSING'; end;
    else if RBC_Storage_Status='negative' then do; CategoryCode='STORAGE_INVALID'; Status='INVALID'; end;
    else do; CategoryCode=cats('STORAGE_',put(Storage_Cat,1.)); Status='VALID'; end;
    CategoryLabel=RBC_Storage_Label; output;
    Factor='DonorSex';
    if missing(DonorSex) then do; CategoryCode='SEX_MISSING'; CategoryLabel='Missing'; Status='MISSING'; end;
    else if DonorSex=1 then do; CategoryCode='M'; CategoryLabel='Male'; Status='VALID'; end;
    else if DonorSex=2 then do; CategoryCode='F'; CategoryLabel='Female'; Status='VALID'; end;
    else do; CategoryCode='SEX_INVALID'; CategoryLabel='Invalid'; Status='INVALID'; end;
    output;
    Factor='DonationWeekday';
    if missing(wdy_donation) then do; CategoryCode='WEEKDAY_MISSING'; CategoryLabel='Missing'; Status='MISSING'; end;
    else if wdy_donation in (1,2,3,4,5,6,7) then do;
      CategoryCode=cats('DAY_',put(wdy_donation,1.)); Status='VALID';
      CategoryLabel=scan('Sunday Monday Tuesday Wednesday Thursday Friday Saturday',wdy_donation,' ');
    end;
    else do; CategoryCode='WEEKDAY_INVALID'; CategoryLabel='Invalid'; Status='INVALID'; end;
    output;
    Factor='DonorParity';
    if DonorSex ne 2 then do;
      Eligible=0; Status='EXCLUDED';
      if DonorSex=1 then do; CategoryCode='EXCLUDED_MALE'; CategoryLabel='Male donor'; end;
      else if missing(DonorSex) then do; CategoryCode='EXCLUDED_MISSING_SEX'; CategoryLabel='Missing donor sex'; end;
      else do; CategoryCode='EXCLUDED_INVALID_SEX'; CategoryLabel='Invalid donor sex'; end;
    end;
    else if RBC_Parity_Status='parity_missing' then do;
      CategoryCode='PARITY_MISSING'; CategoryLabel='Missing parity'; Status='MISSING';
    end;
    else if RBC_Parity_Status='parity_invalid' then do;
      CategoryCode='PARITY_INVALID'; CategoryLabel='Invalid parity'; Status='INVALID';
    end;
    else do;
      CategoryCode=cats('PARITY_',put(DonorParity_Female,1.));
      CategoryLabel=RBC_Parity_Label; Status='VALID';
    end;
    output;
    keep Factor CategoryCode CategoryLabel Status Eligible;
  run;
  proc sql;
    create table work._rdd_catden as select Factor,count(*) as NTotalUnits,
      sum(Eligible) as NEligibleUnits,
      sum(Eligible=1 and Status='VALID') as NValid,
      sum(Eligible=1 and Status='MISSING') as NMissing,
      sum(Eligible=1 and Status='INVALID') as NInvalid,
      sum(Eligible=0) as NExcluded
      from work._rdd_categories group by Factor;
    create table work._rdd_unitcats as select c.Factor,c.CategoryCode,c.CategoryLabel,c.Status,
      c.Eligible,count(*) as No_of_Transfused_Units,d.NTotalUnits,d.NEligibleUnits,
      d.NValid,d.NMissing,d.NInvalid,d.NExcluded,
      case when c.Eligible=1 and d.NEligibleUnits>0 then 100*count(*)/d.NEligibleUnits else . end as Percent,
      case when c.Factor='DonorParity' then 'FEMALE_DONOR_LINKED_INDEX_UNITS'
        else 'ALL_LINKED_INDEX_UNITS' end as DenominatorDefinition length=64
      from work._rdd_categories c inner join work._rdd_catden d on c.Factor=d.Factor
      group by c.Factor,c.CategoryCode,c.CategoryLabel,c.Status,c.Eligible,
        d.NTotalUnits,d.NEligibleUnits,d.NValid,d.NMissing,d.NInvalid,d.NExcluded;
  quit;
  %rdd_step(UNIT_CATEGORY_DESCRIPTORS);
  %if &RBC_DESC_ERROR ne NONE %then %goto finish;
  data work._rdd_meta;
    length AnchorPolicy $32 TiePolicy $48 UnitScope $32 AgeRangePolicy $32
      SAPSOption $3 DescriptorStatus $32;
    AnchorPolicy='FIRST_ELIGIBLE_EVENT'; TiePolicy='REQUIRE_IDENTICAL_DESCRIPTORS';
    UnitScope='ELIGIBLE_INDEX_EVENT_UNITS'; AgeRangePolicy='NO_NEW_CLINICAL_RANGE_FILTER';
    SAPSOption=upcase(symget('include_saps')); DescriptorStatus='LOCAL_COMPUTATION_ONLY';
  run;
  %rdd_step(MANIFEST);
  %if &RBC_DESC_ERROR ne NONE %then %goto finish;
  %let published=1;
  %do i=1 %to %sysfunc(countw(&outputs));
    %let name=%scan(&outputs,&i);
    data &outlib..&name;
      length RunId AnalysisSpecId $64 CohortMode $24 PopulationId $32 DisclosureStatus $24;
      %if &i=2 or &i=3 or &i=4 or &i=5 or &i=6 or &i=8 or &i=9 %then %do;
        length DenominatorDefinition DenominatorScope $64;
      %end;
      %if &i=8 %then %do; length CountDefinition $64; %end;
      set work.%scan(&stages,&i);
      %if &i=2 or &i=3 or &i=4 or &i=5 or &i=6 or &i=8 or &i=9 %then %do;
        Denominator=&n_people;
        DenominatorDefinition='ONE_PERSON_AT_FIRST_ELIGIBLE_EVENT';
        DenominatorScope='SUPPLIED_POPULATION_ELIGIBLE_PERSONS';
      %end;
      %if &i=8 %then %do;
        CountDefinition='PHYSICAL_UNITS_LINKED_TO_SUPPLIED_ELIGIBLE_INDEX_EVENTS';
      %end;
      RunId=symget('run_id'); AnalysisSpecId=symget('analysis_spec_id');
      CohortMode=symget('cohort_mode'); PopulationId=symget('population_id');
      DisclosureStatus='PRIVATE_UNREVIEWED';
      format _numeric_ best32.;
    run;
    %rdd_step(OUTPUT_WRITE);
    %if &RBC_DESC_ERROR ne NONE %then %goto finish;
  %end;
  %let RBC_DESC_OK=1;
%finish:
  %if &made=1 %then %do;
    proc datasets library=work nolist; delete &scratch; quit;
    %if &syserr>4 or &syscc>4 %then %do;
      %let RBC_DESC_OK=0;
      %if &RBC_DESC_ERROR=NONE %then %rdd_fail(SCRATCH_CLEANUP_FAILED);
    %end;
  %end;

  %if &RBC_DESC_OK ne 1 and &published=1 %then %do;
    proc datasets library=&outlib nolist; delete &outputs; quit;
    %do i=1 %to %sysfunc(countw(&outputs));
      %if %sysfunc(exist(&outlib..%scan(&outputs,&i),DATA)) or
          %sysfunc(exist(&outlib..%scan(&outputs,&i),VIEW))
        %then %rdd_fail(OUTPUT_ROLLBACK_FAILED);
    %end;
  %end;
  %if &RBC_DESC_OK ne 1 and %upcase(%superq(on_error)) ne RETURN %then %abort cancel;
%mend;

%macro rob_fail(code);
  %let RBC_OBS_OK=0;
  %let RBC_OBS_ERROR=&code;
  %put NOTE: RBC_OBS_REJECTED &code;
%mend;
%macro rob_step(stage);
  %if &syserr>4 or &syscc>4 %then %rob_fail(STEP_FAILED_&stage);
%mend;
%macro rob_require(ds=,vars=,types=);
  %local lib mem h i pos actual rc;
  %if %sysfunc(countc(%superq(ds),.)) ne 1 %then %do;
    %rob_fail(SIMPLE_TWO_LEVEL_DATA_NAME_REQUIRED); %return;
  %end;
  %let lib=%qscan(%superq(ds),1,.); %let mem=%qscan(%superq(ds),2,.);
  %if %length(%superq(lib))>8 or %length(%superq(mem))>32 or
      not %sysfunc(nvalid(%superq(lib),V7)) or
      not %sysfunc(nvalid(%superq(mem),V7)) %then %do;
    %rob_fail(SIMPLE_TWO_LEVEL_DATA_NAME_REQUIRED); %return;
  %end;
  %if not %sysfunc(exist(&ds,DATA)) %then %do;
    %rob_fail(INPUT_DATA_TABLE_REQUIRED); %return;
  %end;
  %let h=%sysfunc(open(&ds,i));
  %if &h=0 %then %do; %rob_fail(INPUT_METADATA_UNAVAILABLE); %return; %end;
  %do i=1 %to %sysfunc(countw(&vars));
    %let pos=%sysfunc(varnum(&h,%scan(&vars,&i)));
    %if &pos=0 %then %do;
      %let rc=%sysfunc(close(&h)); %rob_fail(REQUIRED_COLUMN_ABSENT); %return;
    %end;
    %let actual=%sysfunc(vartype(&h,&pos));
    %if &actual ne %scan(&types,&i) %then %do;
      %let rc=%sysfunc(close(&h)); %rob_fail(REQUIRED_COLUMN_TYPE_MISMATCH); %return;
    %end;
    %if &actual=C %then %do;
      %if %sysfunc(varlen(&h,&pos))>256 %then %do;
        %let rc=%sysfunc(close(&h)); %rob_fail(CHARACTER_FIELD_TOO_LONG); %return;
      %end;
    %end;
  %end;
  %let rc=%sysfunc(close(&h));
%mend;

%macro rob_candidate;
  %local oi fi f v k g n cats j l modelvars dfvar lovar hivar h rc bad precisionbad rows expected fit_scale fit_scale_hex precision_constant precision_directzero precision_bound precision_unsupported precision_unavailable precision_directbound precision_directsupported scorebad;
  data work._rob_inference;
    length VitalCode $4 Factor $32 Kind $1 Label $32;
    CategoryA=.; CategoryB=.; Estimate=.; StdErr=.; DF=.; Lower=.; Upper=.; PValue=.;
    FitPersons=.; FitEvents=.; FitCategories=.; call missing(of _character_); stop;
  run;
  data work._rob_summary;
    set work._rob_summary;
    InferenceMethod='SURVEYREG_TAYLOR_NONE_T';
    if NDiff=0 then InferenceStatus='NO_PAIRED_EVENTS';
    else if NPairedPatients<2 then InferenceStatus='INSUFFICIENT_CATEGORY_PERSONS';
    else InferenceStatus='INSUFFICIENT_RESIDUAL_INFORMATION';
    FitPersons=.; FitEvents=.; FitCategories=.;
  run;
  data work._rob_pairwise;
    set work._rob_pairwise;
    InferenceMethod='SURVEYREG_TAYLOR_NONE_T';
    if NEventsA=0 or NEventsB=0 then InferenceStatus='NO_PAIRED_EVENTS';
    else if NPersonsA<2 or NPersonsB<2 then InferenceStatus='INSUFFICIENT_CATEGORY_PERSONS';
    else InferenceStatus='INSUFFICIENT_RESIDUAL_INFORMATION';
    FitPersons=.; FitEvents=.; FitCategories=.;
  run;
  %do oi=1 %to 7;
    %let v=%scan(ARTm ARTs ARTd HR FIO2 SPO2 VE,&oi);
    %do fi=1 %to 6;
      %let f=%scan(MAIN DonorHb_Cat Storage_Cat DonorSex DonorParity_Female wdy_donation,&fi);
      %let cats=; %let k=0; %let g=0; %let n=0;
      proc sql noprint;
        select CategoryCode into :cats separated by ' ' from work._rob_summary
          where VitalCode="&v" and Factor="&f" and NDiff>0 order by CategoryCode;
        %let k=&sqlobs;
        select count(*),count(distinct PersonKey) into :n trimmed,:g trimmed
          from work._rob_pairs where VitalCode="&v" and Factor="&f" and Paired=1;
        select put(case when max(Diff_SD)>0 then max(Diff_SD) else 1 end,hex16.)
          into :fit_scale_hex trimmed from work._rob_summary where VitalCode="&v" and Factor="&f";
        update work._rob_summary set FitPersons=&g,FitEvents=&n,FitCategories=&k
          where VitalCode="&v" and Factor="&f";
        update work._rob_pairwise set FitPersons=&g,FitEvents=&n,FitCategories=&k
          where VitalCode="&v" and Factor="&f";
      quit;
      %rob_step(INFERENCE_COUNTS);
      %if &RBC_OBS_ERROR ne NONE %then %return;
      %if &k>0 and &g>=2 and &n>&k %then %do;
        %let bad=0;
        %let fit_scale=input("&fit_scale_hex",hex16.);
        %if not %sysevalf(%sysfunc(inputn(&fit_scale_hex,hex16.))>0) %then %do;
          %rob_fail(INFERENCE_RESPONSE_SCALE_INVALID); %return;
        %end;
        %let modelvars=;
        %do j=1 %to &k; %let modelvars=&modelvars RBO&j; %end;

        proc sql noprint;
          create table work._rob_fit as select p.PersonKey,p.CategoryCode,
            (p.Diff-s.Diff_Mean)/&fit_scale as CenteredDiff
          from work._rob_pairs p inner join work._rob_summary s
            on p.VitalCode=s.VitalCode and p.Factor=s.Factor and p.CategoryCode=s.CategoryCode
          where p.VitalCode="&v" and p.Factor="&f" and p.Paired=1;
        quit;
        data work._rob_fit;
          set work._rob_fit;
          %do j=1 %to &k; RBO&j=(CategoryCode=%scan(&cats,&j)); %end;
          if missing(CenteredDiff) then call symputx('bad',1,'L');
          keep PersonKey CenteredDiff &modelvars;
        run;
        %if &bad ne 0 or &syscc>4 or &syserr>4 %then %do;
          %rob_fail(INFERENCE_RESPONSE_SCALE_INVALID); %return;
        %end;
        proc datasets library=work nolist; delete _rob_ods; quit;
        ods output Estimates=work._rob_ods;
        proc surveyreg data=work._rob_fit varmethod=taylor alpha=0.05;
          cluster PersonKey;
          model CenteredDiff=&modelvars / noint solution vadjust=none;
          %do j=1 %to &k;
            estimate "W_&j" RBO&j 1 / cl;
            %do l=%eval(&j+1) %to &k;
              estimate "P_&j._&l" RBO&j 1 RBO&l -1 / cl;
            %end;
          %end;
        run;
        ods output close;
        %rob_step(PERSON_CLUSTER_FIT);
        %if &RBC_OBS_ERROR ne NONE %then %return;
        %if not %sysfunc(exist(work._rob_ods,DATA)) %then %do;
          %rob_fail(INFERENCE_ESTIMATES_MISSING); %return;
        %end;

        %let h=%sysfunc(open(work._rob_ods,i));
        %if &h=0 %then %do; %rob_fail(INFERENCE_ODS_METADATA_UNAVAILABLE); %return; %end;
        %let dfvar=; %let lovar=; %let hivar=;
        %if %sysfunc(varnum(&h,DF))>0 %then %let dfvar=DF;
        %else %if %sysfunc(varnum(&h,DenDF))>0 %then %let dfvar=DenDF;
        %if %sysfunc(varnum(&h,Lower))>0 %then %let lovar=Lower;
        %else %if %sysfunc(varnum(&h,LowerCL))>0 %then %let lovar=LowerCL;
        %if %sysfunc(varnum(&h,Upper))>0 %then %let hivar=Upper;
        %else %if %sysfunc(varnum(&h,UpperCL))>0 %then %let hivar=UpperCL;
        %let rc=%sysfunc(close(&h));
        %if %length(&dfvar)=0 or %length(&lovar)=0 or %length(&hivar)=0 %then %do;
          %rob_fail(INFERENCE_ODS_SCHEMA_UNSUPPORTED); %return;
        %end;
        %rob_require(ds=work._rob_ods,vars=Label Estimate StdErr Probt &dfvar &lovar &hivar,
          types=C N N N N N N);
        %if &RBC_OBS_ERROR ne NONE %then %return;
        data work._rob_norm;
          length VitalCode $4 Factor $32 Kind $1 Label $32;
          set work._rob_ods(rename=(&dfvar=_DF &lovar=_Lower &hivar=_Upper Probt=_P));
          VitalCode="&v"; Factor="&f"; Kind=scan(Label,1,'_');
          _a=input(scan(Label,2,'_'),?? best32.); _b=input(scan(Label,3,'_'),?? best32.);
          CategoryA=input(scan("&cats",_a,' '),?? best32.);
          if Kind='P' then CategoryB=input(scan("&cats",_b,' '),?? best32.);
          else CategoryB=.;
          DF=_DF; Lower=_Lower; Upper=_Upper; PValue=_P;
          FitPersons=&g; FitEvents=&n; FitCategories=&k;
          Invalid=(missing(Estimate) or missing(StdErr) or StdErr<0 or DF ne &g-1
            or missing(CategoryA) or Kind not in ('P','W')
            or (Kind='P' and (missing(CategoryB) or CategoryA>=CategoryB))
            or (Kind='W' and not missing(_b)));
          if Kind='W' and Label ne cats('W_',_a) then Invalid=1;
          if Kind='P' and Label ne cats('P_',_a,'_',_b) then Invalid=1;
          if StdErr>0 then do;
            _critical=tinv(0.975,DF);
            if nmiss(Lower,Upper,PValue)>0 or PValue<0 or PValue>1 or
              abs(Lower-(Estimate-_critical*StdErr))>1e-8*max(1,abs(Estimate),StdErr) or
              abs(Upper-(Estimate+_critical*StdErr))>1e-8*max(1,abs(Estimate),StdErr) or
              abs(PValue-2*(1-probt(abs(Estimate/StdErr),DF)))>1e-8 then Invalid=1;
          end;
          keep VitalCode Factor Kind Label CategoryA CategoryB Estimate StdErr DF Lower Upper PValue
            FitPersons FitEvents FitCategories Invalid;
        run;
        %let expected=%eval(&k+(&k*(&k-1))/2);
        proc sql noprint;
          select count(*),sum(Invalid) into :rows trimmed,:bad trimmed from work._rob_norm;
          create table work._rob_idup as select Label from work._rob_norm group by Label having count(*) ne 1;
          select count(*)+&bad into :bad trimmed from work._rob_idup;
        quit;
        %rob_step(INFERENCE_VALIDATION);
        %if &RBC_OBS_ERROR ne NONE %then %return;
        %if &rows ne &expected or &bad ne 0 %then %do;
          %rob_fail(INFERENCE_ESTIMATE_OR_DF_INVALID); %return;
        %end;
        proc sql noprint;
          create table work._rob_restore as select i.*,a.Diff_Mean as _MeanA,b.Diff_Mean as _MeanB
          from work._rob_norm i inner join work._rob_summary a on i.VitalCode=a.VitalCode
            and i.Factor=a.Factor and i.CategoryA=a.CategoryCode
          left join work._rob_summary b on i.VitalCode=b.VitalCode
            and i.Factor=b.Factor and i.CategoryB=b.CategoryCode;
        quit;
        data work._rob_norm;
          set work._rob_restore;
          _Shift=_MeanA; if Kind='P' then _Shift=_MeanA-_MeanB;
          Estimate=Estimate*&fit_scale+_Shift; _ScaledSE=StdErr; StdErr=StdErr*&fit_scale;
          if not missing(Lower) then Lower=Lower*&fit_scale+_Shift;
          if not missing(Upper) then Upper=Upper*&fit_scale+_Shift;
           
          if StdErr>0 then PValue=2*probt(-abs(Estimate/StdErr),DF);
          else PValue=.;
          if missing(Estimate) or missing(StdErr) or StdErr<0 or
            (_ScaledSE>0 and (StdErr=0 or StdErr**2=0 or missing(StdErr**2))) or
            (StdErr>0 and (nmiss(Lower,Upper,PValue)>0 or Lower>=Upper))
            then call symputx('bad',1,'L');
          drop _:;
        run;
        %if &bad ne 0 or &syscc>4 or &syserr>4 %then %do;
          %rob_fail(INFERENCE_RESCALE_NOT_REPRESENTABLE); %return;
        %end;
        proc append base=work._rob_inference data=work._rob_norm(drop=Invalid) force; run;
        %rob_step(INFERENCE_ACCUMULATE);
        %if &RBC_OBS_ERROR ne NONE %then %return;
      %end;
    %end;
  %end;

  proc sql noprint;
    select count(*) into :bad trimmed from work._rob_inference i
      left join work._rob_summary s on i.VitalCode=s.VitalCode and i.Factor=s.Factor
        and i.CategoryA=s.CategoryCode
      left join work._rob_summary t on i.VitalCode=t.VitalCode and i.Factor=t.Factor
        and i.CategoryB=t.CategoryCode
      where missing(s.CategoryCode) or missing(s._MeanBound) or
        (i.Kind='W' and abs(i.Estimate-s.Diff_Mean)>s._MeanBound+1e-8*abs(s.Diff_Mean)) or
        (i.Kind='P' and (missing(t.CategoryCode) or missing(t._MeanBound) or
          abs(i.Estimate-(s.Diff_Mean-t.Diff_Mean))>s._MeanBound+t._MeanBound
            +8*constant('MACEPS')*(abs(s.Diff_Mean)+abs(t.Diff_Mean))+1e-8*abs(s.Diff_Mean-t.Diff_Mean)));
    create table work._rob_joined as select s.*,i.StdErr as _SE,i.DF as _DF,
      i.Lower as _Lower,i.Upper as _Upper,i.PValue as _P
      from work._rob_summary s left join work._rob_inference i
        on s.VitalCode=i.VitalCode and s.Factor=i.Factor and s.CategoryCode=i.CategoryA and i.Kind='W';
    create table work._rob_pjoined as select s.*,i.Estimate as _NativeEstimate,i.StdErr as _SE,i.DF as _DF,
      i.Lower as _Lower,i.Upper as _Upper,i.PValue as _P,
      (a._ConstDiff and b._ConstDiff) as _BothConstant
      from work._rob_pairwise s left join work._rob_summary a
        on s.VitalCode=a.VitalCode and s.Factor=a.Factor and s.CategoryA=a.CategoryCode
      left join work._rob_summary b
        on s.VitalCode=b.VitalCode and s.Factor=b.Factor and s.CategoryB=b.CategoryCode
      left join work._rob_inference i
        on s.VitalCode=i.VitalCode and s.Factor=i.Factor and s.CategoryA=i.CategoryA
          and s.CategoryB=i.CategoryB and i.Kind='P';
    create table work._rob_covariance as select a.VitalCode,s.Outcome,a.Factor,a.CategoryA,
      b.CategoryA as CategoryB,
      case when a.CategoryA=b.CategoryA then a.StdErr**2
        else (a.StdErr**2+b.StdErr**2-p.StdErr**2)/2 end as Covariance,
      case when s._ConstDiff then 0 else a.StdErr**2 end as _VarianceA,
      case when t._ConstDiff then 0 else b.StdErr**2 end as _VarianceB,
      s._ConstDiff as _ExactConstantA,t._ConstDiff as _ExactConstantB,
      a.DF,a.FitPersons,a.FitEvents,a.FitCategories,
      case when s.NPairedPatients<2 or t.NPairedPatients<2 then 'INSUFFICIENT_CATEGORY_PERSONS'
        else 'PAIRED_INFERENCE_APPROVED' end as InferenceStatus length=40
      from work._rob_inference a inner join work._rob_inference b
        on a.VitalCode=b.VitalCode and a.Factor=b.Factor and a.Kind='W' and b.Kind='W'
      left join work._rob_inference p on a.VitalCode=p.VitalCode and a.Factor=p.Factor and p.Kind='P'
        and p.CategoryA=min(a.CategoryA,b.CategoryA) and p.CategoryB=max(a.CategoryA,b.CategoryA)
      inner join work._rob_summary s on a.VitalCode=s.VitalCode and a.Factor=s.Factor and a.CategoryA=s.CategoryCode
      inner join work._rob_summary t on b.VitalCode=t.VitalCode and b.Factor=t.Factor and b.CategoryA=t.CategoryCode;
  quit;
  %rob_step(INFERENCE_ALIGNMENT);
  %if &RBC_OBS_ERROR ne NONE %then %return;
  %if &bad ne 0 %then %do; %rob_fail(INFERENCE_DESCRIPTIVE_MEAN_MISMATCH); %return; %end;
  data work._rob_summary;
    set work._rob_joined;

    if _ConstDiff and NDiff>0 and not missing(_SE) then _SE=0;
    if not missing(_SE) and NPairedPatients>=2 then do;
      if _SE>0 then do;
        Diff_SE=_SE; DF=_DF; Diff_LCL=_Lower; Diff_UCL=_Upper; PValue=_P;
        InferenceStatus='PAIRED_INFERENCE_APPROVED'; Status='PAIRED_WITH_PERSON_CLUSTER_INFERENCE';
      end;
      else InferenceStatus='ZERO_VARIANCE_UNAVAILABLE';
    end;
    Pre_InferenceStatus=InferenceStatus; Post_InferenceStatus=InferenceStatus;
    if NDiff>0 and NPairedPatients>=2 then do;
      Pre_InferenceStatus='INSUFFICIENT_RESIDUAL_INFORMATION';
      Post_InferenceStatus='INSUFFICIENT_RESIDUAL_INFORMATION';
    end;
    drop _:;
  run;
  data work._rob_pairwise;
    set work._rob_pjoined;

    if not missing(_NativeEstimate) then Estimate=_NativeEstimate;
    if _BothConstant and NEventsA>0 and NEventsB>0 and not missing(_SE) then _SE=0;
    if not missing(_SE) and NPersonsA>=2 and NPersonsB>=2 then do;
      if _SE>0 then do;
        StdErr=_SE; DF=_DF; Lower=_Lower; Upper=_Upper; PValue=_P;
        InferenceStatus='PAIRED_INFERENCE_APPROVED';
      end;
      else InferenceStatus='ZERO_VARIANCE_UNAVAILABLE';
    end;
    drop _:;
  run;

  proc sql noprint;

    create table work._rob_score_centers as
      select p.VitalCode,p.Factor,p.CategoryCode,
        mean(p.Pre_Avg-s.Pre_Mean) as PreCenter,
        mean(p.Post_Avg-s.Post_Mean) as PostCenter,
        mean(p.Diff-s.Diff_Mean) as ChangeCenter,
        mean(abs(p.Pre_Avg)) as MeanAbsPre,mean(abs(p.Post_Avg)) as MeanAbsPost,mean(abs(p.Diff)) as MeanAbsDiff
      from work._rob_pairs p inner join work._rob_summary s
        on p.VitalCode=s.VitalCode and p.Factor=s.Factor and p.CategoryCode=s.CategoryCode
      where p.Paired=1 and s.FitPersons>=2 and s.FitEvents>s.FitCategories
      group by p.VitalCode,p.Factor,p.CategoryCode;
    create table work._rob_scores as
      select p.VitalCode,p.Factor,p.PersonKey,p.CategoryCode,
        sum((p.Pre_Avg-s.Pre_Mean)-c.PreCenter) as PreScore,
        sum((p.Post_Avg-s.Post_Mean)-c.PostCenter) as PostScore,
        sum((p.Diff-s.Diff_Mean)-c.ChangeCenter) as DirectChangeScore,
        count(*) as PersonEvents,max(s.NDiff) as CategoryEvents,
        max(c.MeanAbsPre) as MeanAbsPre,max(c.MeanAbsPost) as MeanAbsPost,max(c.MeanAbsDiff) as MeanAbsDiff,
        sum(abs(p.Diff)+abs(s.Diff_Mean)) as DiffMagnitude,max(abs(p.Diff)) as MaxAbsDiff,
        sum(abs(p.Pre_Avg)+abs(s.Pre_Mean)+abs(c.PreCenter)+abs(p.Post_Avg)+abs(s.Post_Mean)+abs(c.PostCenter)+abs(p.Diff)+abs(s.Diff_Mean)+abs(c.ChangeCenter)) as ArithmeticMagnitude,
        max(abs((s.Post_Mean-s.Pre_Mean)-s.Diff_Mean)+abs((c.PostCenter-c.PreCenter)-c.ChangeCenter)) as MeanIdentityError
      from work._rob_pairs p inner join work._rob_summary s
        on p.VitalCode=s.VitalCode and p.Factor=s.Factor and p.CategoryCode=s.CategoryCode
      inner join work._rob_score_centers c on p.VitalCode=c.VitalCode and p.Factor=c.Factor and p.CategoryCode=c.CategoryCode
      where p.Paired=1 and s.FitPersons>=2 and s.FitEvents>s.FitCategories
      group by p.VitalCode,p.Factor,p.PersonKey,p.CategoryCode;
  quit;

  %let bad=0;
  data work._rob_lscores(keep=VitalCode Factor PersonKey CategoryCode Metric Score)
       work._rob_identity_scores(keep=VitalCode Factor CategoryCode IdentityScore);
    length Metric $6;
    set work._rob_scores;
    _neps=(8*PersonEvents+32)*constant('MACEPS');
    _ceps=(16*CategoryEvents+64)*constant('MACEPS');
    _invalid=(nmiss(PreScore,PostScore,DirectChangeScore,ArithmeticMagnitude,MeanIdentityError,MeanAbsPre,MeanAbsPost,MeanAbsDiff)>0
      or _neps>=0.001 or _neps<=0 or _ceps>=0.001 or _ceps<=0);
    if not _invalid then do;
      _meanbound=(_ceps/(1-_ceps))*(MeanAbsPre+MeanAbsPost+2*MeanAbsDiff);
      _bound=(_neps/(1-_neps))*ArithmeticMagnitude+PersonEvents*MeanIdentityError;
      _residual=(PostScore-PreScore)-DirectChangeScore;
      _invalid=(missing(_bound) or missing(_meanbound) or MeanIdentityError>_meanbound or abs(_residual)>_bound);
    end;
    if _invalid then call symputx('bad',1,'L');
    else do;
      Metric='PRE'; Score=PreScore; output work._rob_lscores;
      Metric='POST'; Score=PostScore; output work._rob_lscores;
      Metric='CHANGE'; Score=DirectChangeScore; output work._rob_lscores;
      IdentityScore=_residual/CategoryEvents; output work._rob_identity_scores;
    end;
  run;
  %rob_step(JOINT_SCORE_ARITHMETIC);
  %if &RBC_OBS_ERROR ne NONE %then %return;
  %if &bad ne 0 %then %do; %rob_fail(JOINT_SCORE_ARITHMETIC_IDENTITY_UNRESOLVED); %return; %end;
  proc sql noprint;
    create table work._rob_products as
      select a.VitalCode,a.Factor,a.CategoryCode as CategoryA,b.CategoryCode as CategoryB,
        a.Metric as MetricA,b.Metric as MetricB,sum(a.Score*b.Score) as CrossProduct,
        count(*) as ProductCount,n(a.Score*b.Score) as FiniteProducts
      from work._rob_lscores a inner join work._rob_lscores b
        on a.VitalCode=b.VitalCode and a.Factor=b.Factor and a.PersonKey=b.PersonKey
      group by a.VitalCode,a.Factor,a.CategoryCode,b.CategoryCode,a.Metric,b.Metric;
    create table work._rob_identity_norm as
      select VitalCode,Factor,CategoryCode,sum(IdentityScore**2) as IdentitySumSquares,
        max(IdentityScore ne 0) as AnyIdentityNonzero,count(*) as IdentityCount,n(IdentityScore**2) as FiniteIdentitySquares
      from work._rob_identity_scores group by VitalCode,Factor,CategoryCode;
    create table work._rob_score_nonzero as
      select VitalCode,Factor,CategoryCode,Metric,max(Score ne 0) as AnyNonzero
      from work._rob_lscores group by VitalCode,Factor,CategoryCode,Metric;
    select count(*) into :scorebad trimmed from work._rob_products where ProductCount ne FiniteProducts;
    select count(*)+&scorebad into :scorebad trimmed from work._rob_identity_norm
      where IdentityCount ne FiniteIdentitySquares or (AnyIdentityNonzero and IdentitySumSquares=0);
  quit;
  %rob_step(JOINT_SCORE_PRODUCTS);
  %if &RBC_OBS_ERROR ne NONE %then %return;
  %if &scorebad ne 0 %then %do; %rob_fail(JOINT_SCORE_PRODUCT_NOT_REPRESENTABLE); %return; %end;
  data work._rob_metricgrid;
    length Metric $6;
    set work._rob_summary;
    where NDiff>0 and FitPersons>=2 and FitEvents>FitCategories;
    Metric='PRE'; output; Metric='POST'; output; Metric='CHANGE'; output;
    keep VitalCode Outcome Factor CategoryCode Metric NDiff NPairedPatients
      FitPersons FitEvents FitCategories;
  run;
  proc sql noprint;
    create table work._rob_joint_raw as
      select a.VitalCode,a.Outcome,a.Factor,a.CategoryCode as CategoryA,b.CategoryCode as CategoryB,
        a.Metric as MetricA,b.Metric as MetricB,
        (a.FitPersons/(a.FitPersons-1))*coalesce(p.CrossProduct,0)/(a.NDiff*b.NDiff) as Covariance,
        a.FitPersons-1 as DF,a.FitPersons,a.FitEvents,a.FitCategories,
        a.NPairedPatients as PersonsA,b.NPairedPatients as PersonsB
      from work._rob_metricgrid a inner join work._rob_metricgrid b
        on a.VitalCode=b.VitalCode and a.Factor=b.Factor
      left join work._rob_products p on a.VitalCode=p.VitalCode and a.Factor=p.Factor
        and a.CategoryCode=p.CategoryA and b.CategoryCode=p.CategoryB
        and a.Metric=p.MetricA and b.Metric=p.MetricB;

    select count(*) into :precisionbad trimmed from work._rob_covariance c
      inner join work._rob_joint_raw j on c.VitalCode=j.VitalCode and c.Factor=j.Factor
        and c.CategoryA=j.CategoryA and c.CategoryB=j.CategoryB
      where j.MetricA='CHANGE' and j.MetricB='CHANGE' and j.CategoryA=j.CategoryB
        and c._VarianceA=0 and j.Covariance>0
        and c.InferenceStatus='PAIRED_INFERENCE_APPROVED';

    select count(*) into :bad trimmed from work._rob_covariance c
      full join work._rob_joint_raw j on c.VitalCode=j.VitalCode and c.Factor=j.Factor
        and c.CategoryA=j.CategoryA and c.CategoryB=j.CategoryB
      where (j.MetricA='CHANGE' and j.MetricB='CHANGE' or missing(j.MetricA))
        and (missing(c.Factor) or missing(j.Factor) or missing(j.Covariance)
          or (c.InferenceStatus='PAIRED_INFERENCE_APPROVED' and
            ((c.CategoryA=c.CategoryB and abs(c.Covariance-j.Covariance)>1e-8*max(abs(c.Covariance),abs(j.Covariance)))
            or (c.CategoryA ne c.CategoryB and c._VarianceA>0 and c._VarianceB>0
              and abs(c.Covariance-j.Covariance)>1e-8*sqrt(c._VarianceA)*sqrt(c._VarianceB)
                +16*constant('MACEPS')*(c._VarianceA+c._VarianceB))
            or (c.CategoryA ne c.CategoryB and (c._VarianceA=0 or c._VarianceB=0) and j.Covariance ne 0))));
    create table work._rob_jdiag as select * from work._rob_joint_raw
      where CategoryA=CategoryB and MetricA=MetricB;
    select count(*)+&bad into :bad trimmed from work._rob_jdiag where Covariance<0 or missing(Covariance);
    create table work._rob_jointcov as select j.*,a.Covariance as _VarianceA,b.Covariance as _VarianceB
      from work._rob_joint_raw j inner join work._rob_jdiag a
        on j.VitalCode=a.VitalCode and j.Factor=a.Factor and j.CategoryA=a.CategoryA and j.MetricA=a.MetricA
      inner join work._rob_jdiag b
        on j.VitalCode=b.VitalCode and j.Factor=b.Factor and j.CategoryB=b.CategoryA and j.MetricB=b.MetricA;
    create table work._rob_jsummary as select s.*,p.Covariance as _PreVar,q.Covariance as _PostVar,
        case when s.FitPersons>=2 and not missing(d.IdentitySumSquares)
          then sqrt(s.FitPersons/(s.FitPersons-1)*d.IdentitySumSquares) else . end as _IdentityNorm
      from work._rob_summary s left join work._rob_jdiag p on s.VitalCode=p.VitalCode
        and s.Factor=p.Factor and s.CategoryCode=p.CategoryA and p.MetricA='PRE'
      left join work._rob_jdiag q on s.VitalCode=q.VitalCode
        and s.Factor=q.Factor and s.CategoryCode=q.CategoryA and q.MetricA='POST'
      left join work._rob_identity_norm d on s.VitalCode=d.VitalCode and s.Factor=d.Factor and s.CategoryCode=d.CategoryCode;
    select count(*)+&bad into :bad trimmed from work._rob_jdiag j inner join work._rob_score_nonzero n
      on j.VitalCode=n.VitalCode and j.Factor=n.Factor and j.CategoryA=n.CategoryCode and j.MetricA=n.Metric
      where j.PersonsA>=2 and ((j.Covariance=0 and n.AnyNonzero) or (j.Covariance>0 and not n.AnyNonzero));
    select count(*)+&precisionbad into :precisionbad trimmed from work._rob_covariance c inner join work._rob_score_nonzero n
      on c.VitalCode=n.VitalCode and c.Factor=n.Factor and c.CategoryA=n.CategoryCode and n.Metric='CHANGE'
      where c.CategoryA=c.CategoryB and c.InferenceStatus='PAIRED_INFERENCE_APPROVED' and c._VarianceA>0 and not n.AnyNonzero;
  quit;
  %rob_step(JOINT_SCORE_COVARIANCE);
  %if &RBC_OBS_ERROR ne NONE %then %return;
  %if &precisionbad ne 0 %then %do;

    %rob_fail(SAS_CHANGE_VARIANCE_PRECISION_UNRESOLVED); %return;
  %end;
  %if &bad ne 0 %then %do; %rob_fail(JOINT_CHANGE_COVARIANCE_MISMATCH); %return; %end;
  data work._rob_jointcov;
    set work._rob_jointcov;
    length InferenceStatus $40;
    InferenceStatus='PAIRED_INFERENCE_APPROVED';
    if PersonsA<2 or PersonsB<2 then InferenceStatus='INSUFFICIENT_CATEGORY_PERSONS';
    else if _VarianceA=0 or _VarianceB=0 then InferenceStatus='ESTIMATED_ZERO_COVARIANCE';
    if InferenceStatus='INSUFFICIENT_CATEGORY_PERSONS' then do; Covariance=.; DF=.; end;
    else if InferenceStatus='ESTIMATED_ZERO_COVARIANCE' then do;

      Covariance=0; DF=.;
    end;
    drop PersonsA PersonsB _VarianceA _VarianceB;
  run;
  data work._rob_summary;
    set work._rob_jsummary;
    if NPairedPatients>=2 then ScoreIdentityNorm=_IdentityNorm;
    if NPairedPatients>=2 and not missing(_PreVar) then do;
      if _PreVar>0 then do;
        Pre_SE=sqrt(_PreVar); Pre_DF=FitPersons-1;
        Pre_LCL=Pre_Mean-tinv(0.975,Pre_DF)*Pre_SE;
        Pre_UCL=Pre_Mean+tinv(0.975,Pre_DF)*Pre_SE;
        Pre_InferenceStatus='PAIRED_INFERENCE_APPROVED';
      end;
      else Pre_InferenceStatus='ZERO_VARIANCE_UNAVAILABLE';
    end;
    if NPairedPatients>=2 and not missing(_PostVar) then do;
      if _PostVar>0 then do;
        Post_SE=sqrt(_PostVar); Post_DF=FitPersons-1;
        Post_LCL=Post_Mean-tinv(0.975,Post_DF)*Post_SE;
        Post_UCL=Post_Mean+tinv(0.975,Post_DF)*Post_SE;
        Post_InferenceStatus='PAIRED_INFERENCE_APPROVED';
      end;
      else Post_InferenceStatus='ZERO_VARIANCE_UNAVAILABLE';
    end;
    drop _:;
  run;
  data work._rob_covariance;
    set work._rob_covariance;
    if InferenceStatus='INSUFFICIENT_CATEGORY_PERSONS' then do; Covariance=.; DF=.; end;
    else if _VarianceA=0 or _VarianceB=0 then do;

      Covariance=0; DF=.; InferenceStatus='ESTIMATED_ZERO_COVARIANCE';
    end;
    drop _VarianceA _VarianceB _ExactConstantA _ExactConstantB;
  run;
  %rob_step(INFERENCE_STAGING);
%mend;

%macro rbc_observed_summaries(events=,measurements=,groups=,levels=,outlib=,
    run_id=,analysis_spec_id=,cohort_mode=,population_id=,
    mapping_verified=,measurement_grain=,factor_policy=,window_policy=,
    weighting=,inference=SURVEYREG_TAYLOR_NONE_T,on_error=ABORT);
  %global RBC_OBS_OK RBC_OBS_ERROR;
  %local outputs stages scratch i name idvar bad existing made published n_events;
  %let RBC_OBS_OK=0; %let RBC_OBS_ERROR=NONE; %let made=0; %let published=0;
  %let outputs=observed_data_summary factor_observed_data_summary observed_pairwise
      observed_covariance observed_joint_covariance observed_exclusions observed_manifest;
  %let stages=_rob_main _rob_factor _rob_pairwise _rob_covariance _rob_jointcov _rob_exclusions _rob_manifest;
  %let scratch=_rob_events _rob_measurements _rob_groups _rob_levels _rob_expected
      _rob_codes _rob_edup _rob_tdup _rob_mdup _rob_gdup _rob_ldup _rob_mlinks _rob_glinks
      _rob_groupgrid _rob_moments _rob_eventoutcomes _rob_pairs _rob_summary
      _rob_inference _rob_fit _rob_ods _rob_norm _rob_idup _rob_joined _rob_pjoined _rob_restore
      _rob_score_centers _rob_scores _rob_identity_scores _rob_identity_norm _rob_score_nonzero _rob_diaginput _rob_diagscore _rob_diagcat _rob_lscores _rob_products _rob_metricgrid _rob_joint_raw _rob_jdiag _rob_jsummary
      &stages;
  %if &syscc>4 or &syserr>4 %then %do; %rob_fail(FRESH_SAS_SESSION_REQUIRED); %goto finish; %end;
  %if %upcase(%superq(on_error)) ne ABORT and %upcase(%superq(on_error)) ne RETURN
    %then %do; %let on_error=ABORT; %rob_fail(ERROR_POLICY_REQUIRED); %goto finish; %end;
  %if %upcase(%superq(mapping_verified)) ne YES or
      %upcase(%superq(measurement_grain)) ne ONE_EVENT_OUTCOME_TIMESTAMP or
      %upcase(%superq(factor_policy)) ne ALL_UNITS_KNOWN_SAME_CATEGORY or
      %upcase(%superq(window_policy)) ne LEGACY_60_PLUS_MINUS_5_INCLUSIVE or
      %upcase(%superq(weighting)) ne EQUAL_MEASUREMENT_THEN_PAIRED_EVENT
    %then %do; %rob_fail(EXPLICIT_CANONICAL_WINDOW_WEIGHTING_CONTRACT_REQUIRED); %goto finish; %end;
  %if %upcase(%superq(inference)) ne NONE and
      %upcase(%superq(inference)) ne SURVEYREG_TAYLOR_NONE_T %then %do;
    %rob_fail(INFERENCE_OPTION_UNSUPPORTED); %goto finish;
  %end;
  %if %superq(cohort_mode) ne development_sample and %superq(cohort_mode) ne full_cohort
    %then %do; %rob_fail(COHORT_MODE_REQUIRED); %goto finish; %end;
  %if %superq(population_id) ne PRIMARY and %superq(population_id) ne FIRST_EVENT and
      %superq(population_id) ne NO_FOLLOWING_UNIT_12H
    %then %do; %rob_fail(POPULATION_ID_REQUIRED); %goto finish; %end;
  %do i=1 %to 2;
    %let idvar=%scan(run_id analysis_spec_id,&i);
    %if %length(%superq(&idvar))=0 or %length(%superq(&idvar))>64 or
        %sysfunc(prxmatch(/^[A-Za-z0-9_-]+$/,%superq(&idvar))) ne 1
      %then %do; %rob_fail(RUN_AND_SPEC_ID_REQUIRED); %goto finish; %end;
  %end;
  %if %length(%superq(outlib))>8 or not %sysfunc(nvalid(%superq(outlib),V7))
    %then %do; %rob_fail(OUTPUT_LIBRARY_REQUIRED); %goto finish; %end;
  %if %sysfunc(libref(&outlib)) ne 0 %then %do; %rob_fail(OUTPUT_LIBRARY_REQUIRED); %goto finish; %end;
  %rob_require(ds=&events,vars=PersonKey RBC_EventKey ICUAdmissionKey TransDt,types=N C C N);
  %if &RBC_OBS_ERROR ne NONE %then %goto finish;
  %rob_require(ds=&measurements,vars=PersonKey RBC_EventKey VitalCode Datetime Value,types=N C C N N);
  %if &RBC_OBS_ERROR ne NONE %then %goto finish;
  %rob_require(ds=&groups,vars=PersonKey RBC_EventKey Factor CategoryCode Eligible ReasonCode,types=N C C N N C);
  %if &RBC_OBS_ERROR ne NONE %then %goto finish;
  %rob_require(ds=&levels,vars=Factor CategoryCode CategoryLabel,types=C N C);
  %if &RBC_OBS_ERROR ne NONE %then %goto finish;
  %do i=1 %to %sysfunc(countw(&outputs));
    %let name=%scan(&outputs,&i);
    %if %sysfunc(exist(&outlib..&name,DATA)) or %sysfunc(exist(&outlib..&name,VIEW))
      %then %do; %rob_fail(OUTPUT_ALREADY_EXISTS); %goto finish; %end;
  %end;
  proc sql noprint;
    select count(*) into :existing trimmed from dictionary.tables
      where libname='WORK' and substr(upcase(memname),1,5)='_ROB_';
  quit;
  %rob_step(SCRATCH_GUARD);
  %if &RBC_OBS_ERROR ne NONE %then %goto finish;
  %if &existing ne 0 %then %do; %rob_fail(SCRATCH_COLLISION); %goto finish; %end;
  %let made=1;
  data work._rob_events; set &events(keep=PersonKey RBC_EventKey ICUAdmissionKey TransDt); run;
  data work._rob_measurements; set &measurements(keep=PersonKey RBC_EventKey VitalCode Datetime Value); run;
  data work._rob_groups; set &groups(keep=PersonKey RBC_EventKey Factor CategoryCode Eligible ReasonCode); run;
  data work._rob_levels; set &levels(keep=Factor CategoryCode CategoryLabel); run;
  data work._rob_expected;
    length Factor $32;
    Factor='MAIN'; CategoryCode=1; output;
    Factor='DonorHb_Cat'; do CategoryCode=1 to 5; output; end;
    Factor='Storage_Cat'; do CategoryCode=1 to 5; output; end;
    Factor='DonorSex'; do CategoryCode=1 to 2; output; end;
    Factor='DonorParity_Female'; do CategoryCode=0 to 1; output; end;
    Factor='wdy_donation'; do CategoryCode=1 to 7; output; end;
  run;
  data work._rob_codes;
    length VitalCode $4 Outcome $8;
    do OutcomeOrder=1 to 7;
      VitalCode=scan('ARTm ARTs ARTd HR FIO2 SPO2 VE',OutcomeOrder,' ');
      if VitalCode='SPO2' then Outcome='SpO2'; else Outcome=VitalCode;
      output;
    end;
  run;
  %rob_step(PROJECTIONS);
  %if &RBC_OBS_ERROR ne NONE %then %goto finish;
  proc sql noprint;
    select count(*) into :n_events trimmed from work._rob_events;
    select count(*) into :bad trimmed from work._rob_events
      where missing(PersonKey) or missing(RBC_EventKey) or missing(ICUAdmissionKey) or missing(TransDt);
    create table work._rob_edup as select RBC_EventKey from work._rob_events
      group by RBC_EventKey having count(*) ne 1;
    select count(*)+&bad into :bad trimmed from work._rob_edup;
    create table work._rob_tdup as select PersonKey,TransDt from work._rob_events
      group by PersonKey,TransDt having count(*) ne 1;
    select count(*)+&bad into :bad trimmed from work._rob_tdup;
  quit;
  %rob_step(EVENT_KEYS);
  %if &RBC_OBS_ERROR ne NONE %then %goto finish;
  %if &n_events=0 or &bad ne 0 %then %do; %rob_fail(EVENT_KEYS_NONEMPTY_UNIQUE_REQUIRED); %goto finish; %end;
  proc sql noprint;
    select count(*) into :bad trimmed from work._rob_measurements
      where missing(PersonKey) or missing(RBC_EventKey) or missing(Datetime)
        or VitalCode not in ('ARTm','ARTs','ARTd','HR','FIO2','SPO2','VE');
    create table work._rob_mdup as select RBC_EventKey,VitalCode,Datetime
      from work._rob_measurements group by RBC_EventKey,VitalCode,Datetime having count(*) ne 1;
    select count(*)+&bad into :bad trimmed from work._rob_mdup;
    create table work._rob_mlinks as select m.RBC_EventKey from work._rob_measurements m
      left join work._rob_events e on m.RBC_EventKey=e.RBC_EventKey and m.PersonKey=e.PersonKey
      where missing(e.RBC_EventKey);
    select count(*)+&bad into :bad trimmed from work._rob_mlinks;
  quit;
  %rob_step(MEASUREMENT_GRAIN);
  %if &RBC_OBS_ERROR ne NONE %then %goto finish;
  %if &bad ne 0 %then %do; %rob_fail(MEASUREMENT_KEY_GRAIN_OR_LINK_INVALID); %goto finish; %end;
  proc sql noprint;
    create table work._rob_ldup as select Factor,CategoryCode from work._rob_levels
      group by Factor,CategoryCode having count(*) ne 1;
    select count(*) into :bad trimmed from work._rob_ldup;
    select count(*)+&bad into :bad trimmed from work._rob_levels l
      left join work._rob_expected x on l.Factor=x.Factor and l.CategoryCode=x.CategoryCode
      where missing(x.Factor) or missing(l.CategoryLabel) or lengthn(l.CategoryLabel)>128;
    select count(*)+&bad into :bad trimmed from work._rob_expected x
      left join work._rob_levels l on l.Factor=x.Factor and l.CategoryCode=x.CategoryCode
      where missing(l.Factor);
  quit;
  %rob_step(DECLARED_LEVELS);
  %if &RBC_OBS_ERROR ne NONE %then %goto finish;
  %if &bad ne 0 %then %do; %rob_fail(COMPLETE_CANONICAL_LEVELS_REQUIRED); %goto finish; %end;
  proc sql noprint;
    create table work._rob_gdup as select RBC_EventKey,Factor from work._rob_groups
      group by RBC_EventKey,Factor having count(*) ne 1;
    select count(*) into :bad trimmed from work._rob_gdup;
    select count(*)+&bad into :bad trimmed from work._rob_groups g
      left join work._rob_events e on g.RBC_EventKey=e.RBC_EventKey and g.PersonKey=e.PersonKey
      left join (select distinct Factor from work._rob_expected) f on g.Factor=f.Factor
      left join work._rob_expected l on g.Factor=l.Factor and g.CategoryCode=l.CategoryCode
      where missing(e.RBC_EventKey) or missing(f.Factor) or g.Eligible not in (0,1)
        or missing(g.ReasonCode) or not prxmatch('/^[A-Z][A-Z_0-9]*$/',strip(g.ReasonCode))
        or lengthn(g.ReasonCode)>64
        or (g.Eligible=1 and missing(l.Factor))
        or (g.Eligible=0 and not missing(g.CategoryCode))
        or (g.Factor='MAIN' and (g.Eligible ne 1 or g.CategoryCode ne 1));
    create table work._rob_groupgrid as select e.RBC_EventKey,f.Factor
      from work._rob_events e cross join (select distinct Factor from work._rob_expected) f;
    select count(*)+&bad into :bad trimmed from work._rob_groupgrid x
      left join work._rob_groups g on x.RBC_EventKey=g.RBC_EventKey and x.Factor=g.Factor
      where missing(g.RBC_EventKey);
  quit;
  %rob_step(EVENT_FACTOR_GRID);
  %if &RBC_OBS_ERROR ne NONE %then %goto finish;
  %if &bad ne 0 %then %do; %rob_fail(EVENT_FACTOR_GRID_OR_ELIGIBILITY_INVALID); %goto finish; %end;

  proc sql noprint;
    create table work._rob_moments as select m.RBC_EventKey,m.VitalCode,count(*) as NOutcomeRecords,
      sum(-65 <= (m.Datetime-e.TransDt)/60 and (m.Datetime-e.TransDt)/60 <= -55) as NPreWindowRecords,
      sum(55 <= (m.Datetime-e.TransDt)/60 and (m.Datetime-e.TransDt)/60 <= 65) as NPostWindowRecords,
      sum(-65 <= (m.Datetime-e.TransDt)/60 and (m.Datetime-e.TransDt)/60 <= -55 and not missing(m.Value)) as NPreValues,
      sum(55 <= (m.Datetime-e.TransDt)/60 and (m.Datetime-e.TransDt)/60 <= 65 and not missing(m.Value)) as NPostValues,
      case when min(case when -65 <= (m.Datetime-e.TransDt)/60 and (m.Datetime-e.TransDt)/60 <= -55 then m.Value else . end)=max(case when -65 <= (m.Datetime-e.TransDt)/60 and (m.Datetime-e.TransDt)/60 <= -55 then m.Value else . end) then min(case when -65 <= (m.Datetime-e.TransDt)/60 and (m.Datetime-e.TransDt)/60 <= -55 then m.Value else . end)
        else mean(case when -65 <= (m.Datetime-e.TransDt)/60 and (m.Datetime-e.TransDt)/60 <= -55 then m.Value else . end) end as Pre_Avg,
      case when min(case when 55 <= (m.Datetime-e.TransDt)/60 and (m.Datetime-e.TransDt)/60 <= 65 then m.Value else . end)=max(case when 55 <= (m.Datetime-e.TransDt)/60 and (m.Datetime-e.TransDt)/60 <= 65 then m.Value else . end) then min(case when 55 <= (m.Datetime-e.TransDt)/60 and (m.Datetime-e.TransDt)/60 <= 65 then m.Value else . end)
        else mean(case when 55 <= (m.Datetime-e.TransDt)/60 and (m.Datetime-e.TransDt)/60 <= 65 then m.Value else . end) end as Post_Avg
      from work._rob_measurements m inner join work._rob_events e on m.RBC_EventKey=e.RBC_EventKey
      group by m.RBC_EventKey,m.VitalCode;
    create table work._rob_eventoutcomes as select e.PersonKey,e.RBC_EventKey,c.OutcomeOrder,c.VitalCode,c.Outcome,
      coalesce(m.NOutcomeRecords,0) as NOutcomeRecords,
      coalesce(m.NPreWindowRecords,0) as NPreWindowRecords,
      coalesce(m.NPostWindowRecords,0) as NPostWindowRecords,
      coalesce(m.NPreValues,0) as NPreValues,coalesce(m.NPostValues,0) as NPostValues,m.Pre_Avg,m.Post_Avg,
      (coalesce(m.NPreValues,0)>0) as PreAvailable,(coalesce(m.NPostValues,0)>0) as PostAvailable,
      (coalesce(m.NPreValues,0)>0 and coalesce(m.NPostValues,0)>0) as Paired,
      case when coalesce(m.NPreValues,0)>0 and coalesce(m.NPostValues,0)>0 then m.Post_Avg-m.Pre_Avg else . end as Diff
      from work._rob_events e cross join work._rob_codes c left join work._rob_moments m
        on e.RBC_EventKey=m.RBC_EventKey and c.VitalCode=m.VitalCode;
    create table work._rob_pairs as select a.*,g.Factor,g.CategoryCode
      from work._rob_eventoutcomes a inner join work._rob_groups g on a.RBC_EventKey=g.RBC_EventKey
      where g.Eligible=1;
    create table work._rob_summary as select c.OutcomeOrder,c.VitalCode,c.Outcome,l.Factor,l.CategoryCode,l.CategoryLabel,
      count(a.RBC_EventKey) as NEligibleEvents,
      count(distinct a.PersonKey) as NEligiblePatients,
      sum(case when a.PreAvailable=1 then 1 else 0 end) as NPreAvailableEvents,
      sum(case when a.PostAvailable=1 then 1 else 0 end) as NPostAvailableEvents,
      sum(case when a.Paired=1 then 1 else 0 end) as NDiff,
      count(distinct case when a.Paired=1 then a.PersonKey else . end) as NPairedPatients,
      sum(case when a.PreAvailable=1 and a.PostAvailable=0 then 1 else 0 end) as NPreOnlyEvents,
      sum(case when a.PreAvailable=0 and a.PostAvailable=1 then 1 else 0 end) as NPostOnlyEvents,
      sum(case when a.PreAvailable=0 and a.PostAvailable=0 then 1 else 0 end) as NNeitherAvailableEvents,
      sum(coalesce(a.NPreWindowRecords,0)) as NPreWindowRecords,
      sum(coalesce(a.NPostWindowRecords,0)) as NPostWindowRecords,
      sum(case when a.Paired=1 then a.NPreValues else 0 end) as NPairedPreValues,
      sum(case when a.Paired=1 then a.NPostValues else 0 end) as NPairedPostValues,
      case when min(case when a.Paired=1 then a.Pre_Avg else . end)=max(case when a.Paired=1 then a.Pre_Avg else . end) then min(case when a.Paired=1 then a.Pre_Avg else . end)
        else mean(case when a.Paired=1 then a.Pre_Avg else . end) end as Pre_Mean,
      std(case when a.Paired=1 then a.Pre_Avg else . end) as Pre_SD,
      case when min(case when a.Paired=1 then a.Post_Avg else . end)=max(case when a.Paired=1 then a.Post_Avg else . end) then min(case when a.Paired=1 then a.Post_Avg else . end)
        else mean(case when a.Paired=1 then a.Post_Avg else . end) end as Post_Mean,
      std(case when a.Paired=1 then a.Post_Avg else . end) as Post_SD,
      case when min(case when a.Paired=1 then a.Diff else . end)=max(case when a.Paired=1 then a.Diff else . end) then min(case when a.Paired=1 then a.Diff else . end)
        else mean(case when a.Paired=1 then a.Diff else . end) end as Diff_Mean,
      (min(case when a.Paired=1 then a.Diff else . end)=max(case when a.Paired=1 then a.Diff else . end)) as _ConstDiff,
      std(case when a.Paired=1 then a.Diff else . end) as Diff_SD,
      mean(case when a.Paired=1 then abs(a.Diff) else . end) as _MeanAbsDiff
      from work._rob_codes c cross join work._rob_levels l left join work._rob_pairs a
        on c.VitalCode=a.VitalCode and l.Factor=a.Factor and l.CategoryCode=a.CategoryCode
      group by c.OutcomeOrder,c.VitalCode,c.Outcome,l.Factor,l.CategoryCode,l.CategoryLabel;
    create table work._rob_exclusions as select Factor,ReasonCode,count(*) as NExcludedEvents,
      count(distinct PersonKey) as NExcludedPatients
      from work._rob_groups where Eligible=0 group by Factor,ReasonCode;
  quit;
  %rob_step(PAIRED_DESCRIPTORS);
  %if &RBC_OBS_ERROR ne NONE %then %goto finish;
  data work._rob_summary;
    set work._rob_summary;
    length Abbreviation $8 FactorName $32 FactorCategory $32
      InferenceMethod $64 DenominatorDefinition $64 Status $40 InferenceStatus $40
      Pre_InferenceStatus Post_InferenceStatus $40;
    Abbreviation=Outcome; FactorName=Factor; FactorCategory=strip(put(CategoryCode,best32.));
    WindowHalfWidthMinutes=5;
    _meanEps=(16*NDiff+64)*constant('MACEPS');
    if _meanEps<0.001 then _MeanBound=(_meanEps/(1-_meanEps))*_MeanAbsDiff;
    else _MeanBound=.;
    Diff_SE=.; Diff_LCL=.; Diff_UCL=.; DF=.; PValue=.;
    Pre_SE=.; Pre_DF=.; Pre_LCL=.; Pre_UCL=.; Post_SE=.; Post_DF=.; Post_LCL=.; Post_UCL=.;
    FitPersons=.; FitEvents=.; FitCategories=.; ScoreIdentityNorm=.;
    Pre_InferenceStatus='NOT_REQUESTED'; Post_InferenceStatus='NOT_REQUESTED';
    InferenceMethod='NONE'; InferenceStatus='NOT_REQUESTED';
    DenominatorDefinition='PAIRED_EVENTS_IN_DECLARED_FACTOR_CATEGORY';
    if NDiff=0 then Status='NO_PAIRED_EVENTS'; else Status='DESCRIPTIVE_ONLY';
  run;
  proc sql noprint;
    create table work._rob_pairwise as select a.OutcomeOrder,a.VitalCode,a.Outcome,a.Factor,
      a.CategoryCode as CategoryA,b.CategoryCode as CategoryB,
      a.NDiff as NEventsA,b.NDiff as NEventsB,
      a.NPairedPatients as NPersonsA,b.NPairedPatients as NPersonsB,
      case when a.NDiff>0 and b.NDiff>0 then a.Diff_Mean-b.Diff_Mean else . end as Estimate,
      . as StdErr,. as DF,. as Lower,. as Upper,. as PValue,
      'NOT_REQUESTED' as InferenceStatus length=40,
      'NONE' as InferenceMethod length=64,
      . as FitPersons,. as FitEvents,. as FitCategories
      from work._rob_summary a inner join work._rob_summary b
        on a.VitalCode=b.VitalCode and a.Factor=b.Factor and a.CategoryCode<b.CategoryCode;
  quit;
  data work._rob_covariance;
    length VitalCode $4 Outcome $8 Factor $32 InferenceStatus $40;
    CategoryA=.; CategoryB=.; Covariance=.; DF=.;
    FitPersons=.; FitEvents=.; FitCategories=.; call missing(of _character_); stop;
  run;
  data work._rob_jointcov;
    length VitalCode $4 Outcome $8 Factor $32 MetricA MetricB $6 InferenceStatus $40;
    CategoryA=.; CategoryB=.; Covariance=.; DF=.;
    FitPersons=.; FitEvents=.; FitCategories=.; call missing(of _character_); stop;
  run;
  %if %upcase(%superq(inference))=SURVEYREG_TAYLOR_NONE_T %then %do;
    %rob_candidate;
    %if &RBC_OBS_ERROR ne NONE %then %goto finish;
  %end;
  data work._rob_main; set work._rob_summary; drop _:; where Factor='MAIN'; run;
  data work._rob_factor; set work._rob_summary; drop _:; where Factor ne 'MAIN'; run;
  data work._rob_manifest;
    length WindowPolicy $40 Weighting $48 PairingDefinition $64 ValueScale $48
      InferenceApprovalStatus $40 AnalysisRole $40 ClusterUnit $32 VarianceAdjustment $32
      IntervalDistribution $32 JointCovarianceSource $40 ResponseCentering $48;
    WindowPolicy='LEGACY_60_PLUS_MINUS_5_INCLUSIVE';
    PreLowerMinutes=-65; PreUpperMinutes=-55; PostLowerMinutes=55; PostUpperMinutes=65;
    Weighting='EQUAL_MEASUREMENT_THEN_PAIRED_EVENT';
    PairingDefinition='ONE_PERSON_EVENT_OUTCOME_INTERSECTION';
    ValueScale='SUPPLIED_CANONICAL_VALUE_SCALE';
    InferenceApprovalStatus='NOT_REQUESTED';
    if upcase(symget('inference')) ne 'NONE' then InferenceApprovalStatus='PAIRED_INFERENCE_APPROVED';
    AnalysisRole='SECONDARY_OBSERVED_SUMMARY';
    ConfidenceLevel=.; ClusterUnit='NOT_REQUESTED'; VarianceAdjustment='NOT_REQUESTED';
    IntervalDistribution='NOT_REQUESTED'; JointCovarianceSource='NOT_REQUESTED'; ResponseCentering='NOT_REQUESTED';
    if upcase(symget('inference')) ne 'NONE' then do;
      ConfidenceLevel=0.95; ClusterUnit='VERIFIED_PERSON'; VarianceAdjustment='VADJUST_NONE_CLUSTER_G_OVER_G_1';
      IntervalDistribution='T_WITH_G_MINUS_1_DF'; JointCovarianceSource='SAME_PAIRED_PERSON_SCORES';
      ResponseCentering='CATEGORY_CENTER_SHARED_MAX_CHANGE_SD';
    end;
  run;
  %rob_step(OUTPUT_STAGING);
  %if &RBC_OBS_ERROR ne NONE %then %goto finish;
  %let published=1;
  %do i=1 %to %sysfunc(countw(&outputs));
    %let name=%scan(&outputs,&i);
    data &outlib..&name;
      length RunId AnalysisSpecId $64 CohortMode $24 PopulationId $32 DisclosureStatus $24
        InferenceApprovalStatus $40;
      set work.%scan(&stages,&i);
      RunId=symget('run_id'); AnalysisSpecId=symget('analysis_spec_id');
      CohortMode=symget('cohort_mode'); PopulationId=symget('population_id');
      DisclosureStatus='PRIVATE_UNREVIEWED';
      InferenceApprovalStatus='NOT_REQUESTED';
      if upcase(symget('inference')) ne 'NONE' then InferenceApprovalStatus='PAIRED_INFERENCE_APPROVED';
      format _numeric_ best32.;
    run;
    %rob_step(OUTPUT_WRITE);
    %if &RBC_OBS_ERROR ne NONE %then %goto finish;
  %end;
  %let RBC_OBS_OK=1;
%finish:
  %if &made=1 %then %do;
    proc datasets library=work nolist; delete &scratch; quit;
    %if &syserr>4 or &syscc>4 %then %do;
      %let RBC_OBS_OK=0;
      %if &RBC_OBS_ERROR=NONE %then %rob_fail(SCRATCH_CLEANUP_FAILED);
    %end;
  %end;
  %if &RBC_OBS_OK ne 1 and &published=1 %then %do;
    proc datasets library=&outlib nolist; delete &outputs; quit;
    %do i=1 %to %sysfunc(countw(&outputs));
      %if %sysfunc(exist(&outlib..%scan(&outputs,&i),DATA)) or
          %sysfunc(exist(&outlib..%scan(&outputs,&i),VIEW))
        %then %rob_fail(OUTPUT_ROLLBACK_FAILED);
    %end;
  %end;
  %if &RBC_OBS_OK ne 1 and %upcase(%superq(on_error)) ne RETURN %then %abort cancel;
%mend;

%macro rgr_stop(reason);
 %global RBC_REFRESH_OK RBC_REFRESH_REASON;
 %let RBC_REFRESH_OK=0; %let RBC_REFRESH_REASON=&reason;
 %put NOTE: RBC_REPORT_REFRESH_REJECT &reason;
 %abort cancel;
%mend;
%macro rgr_step;
 %if &syscc>4 or &syserr>4 %then %rgr_stop(SAS_STEP_FAILED);
%mend;
%macro rbc_refresh_population_report(preparedlib=,outlib=,population_id=,
 run_id=,analysis_spec_id=,cohort_mode=,input_snapshot_id=,code_hash=,config_hash=,
 report_run_id=,report_code_hash=,report_config_hash=,oxygen_units=UNVERIFIED);
 %global RBC_REFRESH_OK RBC_REFRESH_REASON RBC_REPORT_EXPORT_REASON;
 %local i v n bad existing;
 %let RBC_REFRESH_OK=0; %let RBC_REFRESH_REASON=NOT_COMPLETED; %let bad=0;
 %rgr_step;
 %if %superq(cohort_mode) ne development_sample and %superq(cohort_mode) ne full_cohort %then %rgr_stop(COHORT_MODE_REQUIRED);
 %if %superq(population_id) ne PRIMARY and %superq(population_id) ne FIRST_EVENT and
     %superq(population_id) ne NO_FOLLOWING_UNIT_12H %then %rgr_stop(POPULATION_INVALID);
 %if %superq(oxygen_units) ne UNVERIFIED and %superq(oxygen_units) ne PERCENT %then %rgr_stop(OXYGEN_OPTION_INVALID);
 %do i=1 %to 2;
  %let v=%scan(preparedlib outlib,&i);
  %if %length(%superq(&v))<1 or %length(%superq(&v))>8 or not %sysfunc(nvalid(%superq(&v),V7)) %then %rgr_stop(LIBRARY_NAME_INVALID);
  %if %sysfunc(libref(&&&v)) ne 0 %then %rgr_stop(LIBRARY_UNASSIGNED);
 %end;
 %if %upcase(&preparedlib)=%upcase(&outlib) %then %rgr_stop(SEPARATE_LIBRARIES_REQUIRED);
 %do i=1 %to 2;
  %let v=%scan(run_id report_run_id,&i);
  %if %length(%superq(&v)) ne 32 or %sysfunc(prxmatch(/^[0-9a-f]{32}$/,%superq(&v))) ne 1 %then %rgr_stop(RUN_ID_INVALID);
 %end;
 %do i=1 %to 4;
  %let v=%scan(code_hash config_hash report_code_hash report_config_hash,&i);
  %if %length(%superq(&v)) ne 64 or %sysfunc(prxmatch(/^[0-9a-f]{64}$/,%superq(&v))) ne 1 %then %rgr_stop(HASH_INVALID);
 %end;
 %let RBC_REPORT_EXPORT_REASON=NOT_COMPLETED;
 %rge_schema(data=&preparedlib..pipeline_identity,
  chars=RunId AnalysisSpecId CohortMode InputSnapshotId CodeHash ConfigHash ExecutionStatus DisclosureStatus,nums=);
 %if &RBC_REPORT_EXPORT_REASON ne NOT_COMPLETED %then %rgr_stop(PREPARATION_IDENTITY_SCHEMA_INVALID);
 %let n=0;
 data _null_;
  set &preparedlib..pipeline_identity(keep=RunId AnalysisSpecId CohortMode InputSnapshotId CodeHash ConfigHash ExecutionStatus DisclosureStatus) end=last;
  if RunId ne symget('run_id') or AnalysisSpecId ne symget('analysis_spec_id') or CohortMode ne symget('cohort_mode')
    or InputSnapshotId ne symget('input_snapshot_id') or CodeHash ne symget('code_hash') or ConfigHash ne symget('config_hash')
    or ExecutionStatus ne 'PREPARATION_COMPLETE' or DisclosureStatus ne 'PRIVATE_UNREVIEWED' then call symputx('bad',1,'L');
  if last then call symputx('n',_n_,'L');
 run;
 %rgr_step;
 %if &bad ne 0 or &n ne 1 %then %rgr_stop(PREPARATION_IDENTITY_MISMATCH);
 proc sql noprint;
  select count(*) into :existing trimmed from dictionary.tables where libname="%upcase(&outlib)";
  select count(*)+&existing into :existing trimmed from dictionary.tables where libname='WORK' and substr(upcase(memname),1,5)='_RGR_';
 quit;
 %rgr_step;
 %if &existing ne 0 %then %rgr_stop(FRESH_OUTPUT_AND_SCRATCH_REQUIRED);
 proc sql noprint;
  create table work._rgr_events as select e.* from &preparedlib..canonical_events e
   inner join &preparedlib..population_members p on e.RBC_EventKey=p.RBC_EventKey where p.PopulationId="&population_id";
  select count(*) into :n trimmed from work._rgr_events;
  create table work._rgr_long as select e.* from &preparedlib..canonical_long e
   inner join work._rgr_events p on e.RBC_EventKey=p.RBC_EventKey;
  create table work._rgr_units as select e.* from &preparedlib..index_units e
   inner join work._rgr_events p on e.RBC_EventKey=p.RBC_EventKey;
  create table work._rgr_groups as select e.* from &preparedlib..event_factor_eligibility e
   inner join work._rgr_events p on e.RBC_EventKey=p.RBC_EventKey;
 quit;
 %rgr_step;
 %if &n>0 %then %do;
  %rbc_descriptive_tables(events=work._rgr_events,units=work._rgr_units,age_bands=&preparedlib..age_bands,
   outlib=&outlib,run_id=&report_run_id,analysis_spec_id=&analysis_spec_id,cohort_mode=&cohort_mode,population_id=&population_id,
   mapping_verified=YES,unit_scope=ELIGIBLE_INDEX_EVENT_UNITS,anchor_policy=FIRST_ELIGIBLE_EVENT,tie_policy=REQUIRE_IDENTICAL_DESCRIPTORS,include_saps=YES);
  %if &RBC_DESC_OK ne 1 %then %rgr_stop(DESCRIPTORS_FAILED);
  %rbc_quality_diagnostics(data=work._rgr_long,outlib=&outlib,run_id=&report_run_id,analysis_spec_id=&analysis_spec_id,
   cohort_mode=&cohort_mode,population_id=&population_id,mapping_verified=YES,oxygen_units=&oxygen_units);
  %if &RBC_QA_OK ne 1 %then %rgr_stop(QUALITY_REPORTS_FAILED);
  %rbc_observed_summaries(events=work._rgr_events,measurements=work._rgr_long,groups=work._rgr_groups,
   levels=&preparedlib..factor_levels,outlib=&outlib,run_id=&report_run_id,analysis_spec_id=&analysis_spec_id,
   cohort_mode=&cohort_mode,population_id=&population_id,mapping_verified=YES,
   measurement_grain=ONE_EVENT_OUTCOME_TIMESTAMP,factor_policy=ALL_UNITS_KNOWN_SAME_CATEGORY,
   window_policy=LEGACY_60_PLUS_MINUS_5_INCLUSIVE,weighting=EQUAL_MEASUREMENT_THEN_PAIRED_EVENT,
   inference=SURVEYREG_TAYLOR_NONE_T);
  %if &RBC_OBS_OK ne 1 %then %rgr_stop(OBSERVED_REPORTS_FAILED);
 %end;
 data &outlib..report_status;
  length PopulationId $32 Status $40 DisclosureStatus $24;
  PopulationId=symget('population_id'); Status='COMPLETE'; if &n=0 then Status='EMPTY_POPULATION';
  DisclosureStatus='PRIVATE_UNREVIEWED';
 run;
 %rgr_step;
 proc datasets library=work nolist; delete _rgr_events _rgr_long _rgr_units _rgr_groups; quit;
 %rgr_step;
 data &outlib..report_identity;
  length RunId AnalysisSpecId InputSnapshotId CodeHash ConfigHash ReportRunId ReportCodeHash ReportConfigHash $64
   CohortMode DisclosureStatus $24 PopulationId $32 ReportStatus $32;
  RunId=symget('run_id'); AnalysisSpecId=symget('analysis_spec_id'); InputSnapshotId=symget('input_snapshot_id');
  CodeHash=symget('code_hash'); ConfigHash=symget('config_hash'); CohortMode=symget('cohort_mode');
  ReportRunId=symget('report_run_id'); ReportCodeHash=symget('report_code_hash'); ReportConfigHash=symget('report_config_hash');
  PopulationId=symget('population_id'); DisclosureStatus='PRIVATE_UNREVIEWED'; ReportStatus='REPORTS_COMPLETE';
 run;
 %rgr_step;
 %let RBC_REFRESH_OK=1; %let RBC_REFRESH_REASON=REPORTS_COMPLETE;
%mend;

