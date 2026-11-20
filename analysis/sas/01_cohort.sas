/* Cohort and event preparation.
   Canonical patients, admissions, index events, physical units, prior-unit count, duplicate reconciliation, eligibility, follow-up populations and preparation flow.
   This file defines macros; use run.py to execute the analysis steps.
*/
%macro rps_fail(code);
  %let RBC_PREPARE_OK=0; %let RBC_PREPARE_ERROR=&code;
  %put NOTE: RBC_PREPARE_REJECTED &code;
%mend;
%macro rps_step(stage);
  %let RBC_PREPARE_STAGE=&stage;
  %if &syscc>4 or &syserr>4 %then %rps_fail(SAS_STEP_FAILED_&stage);
%mend;
%macro rps_require(ds=,vars=,types=);
  %local lib mem h i pos rc nr nb;
  %if %sysfunc(countc(%superq(ds),.)) ne 1 %then %do;
    %rps_fail(SIMPLE_TWO_LEVEL_DATA_NAME_REQUIRED); %return;
  %end;
  %let lib=%qscan(%superq(ds),1,.); %let mem=%qscan(%superq(ds),2,.);
  %if %length(%superq(lib))>8 or %length(%superq(mem))>32 or
      not %sysfunc(nvalid(%superq(lib),V7)) or not %sysfunc(nvalid(%superq(mem),V7))
    %then %do; %rps_fail(SIMPLE_TWO_LEVEL_DATA_NAME_REQUIRED); %return; %end;
  %if not %sysfunc(exist(&ds,DATA)) %then %do;
    %rps_fail(SOURCE_DATA_TABLE_REQUIRED); %return;
  %end;
  proc sql noprint;
    select count(*),coalesce(sum(upcase(strip(readonly)) ne 'YES'),0)
      into :nr trimmed,:nb trimmed from dictionary.libnames where libname=upcase("&lib");
  quit;
  %rps_step(SOURCE_READONLY);
  %if &RBC_PREPARE_ERROR ne NONE %then %return;
  %if &nr=0 or &nb ne 0 %then %do; %rps_fail(SOURCE_READONLY_REQUIRED); %return; %end;
  %let h=%sysfunc(open(&ds,i));
  %if &h=0 %then %do; %rps_fail(SOURCE_METADATA_UNAVAILABLE); %return; %end;
  %do i=1 %to %sysfunc(countw(&vars));
    %let pos=%sysfunc(varnum(&h,%scan(&vars,&i)));
    %if &pos=0 %then %do;
      %let rc=%sysfunc(close(&h)); %rps_fail(REQUIRED_COLUMN_ABSENT); %return;
    %end;
    %if %sysfunc(vartype(&h,&pos)) ne %scan(&types,&i) %then %do;
      %let rc=%sysfunc(close(&h)); %rps_fail(REQUIRED_COLUMN_TYPE_MISMATCH); %return;
    %end;
    %if %scan(&types,&i)=C %then %do;
      %if %sysfunc(varlen(&h,&pos))>256 %then %do;
        %let rc=%sysfunc(close(&h)); %rps_fail(SOURCE_TEXT_LENGTH_EXCEEDED); %return;
      %end;
    %end;
  %end;
  %let rc=%sysfunc(close(&h));
%mend;
%macro rbc_prepare_source(index=,ledger=,admissions=,outlib=,run_id=,
    analysis_spec_id=,input_snapshot_id=,code_hash=,config_hash=,
    cohort_mode=development_sample,model_grouping=UNRESOLVED,
    donation_date_unit=DATETIME,medication_reconciliation=STRICT,science_frozen=NO,on_error=ABORT);
  %global RBC_PREPARE_OK RBC_PREPARE_ERROR RBC_PREPARE_STAGE RBC_PCF_READY
    RBC_PCF_1 RBC_PCF_2 RBC_PCF_3 RBC_PCF_4 RBC_PCF_5 RBC_PCF_6 RBC_PCF_7 RBC_PCF_8 RBC_PCF_9 RBC_PCF_10 RBC_PCF_11 RBC_PCF_12 RBC_PCF_13 RBC_PCF_14 RBC_PCF_15 RBC_PCF_16 RBC_PCF_17 RBC_PCF_18 RBC_PCF_19 RBC_PCF_20 RBC_PCF_21 RBC_PCF_22 RBC_PCF_23 RBC_PCF_24 RBC_PCF_25 RBC_PCF_26 RBC_PCF_27 RBC_PCF_28 RBC_PCF_29 RBC_PCF_30 RBC_PCF_31 RBC_PCF_32 RBC_PCF_33 RBC_PCF_34 RBC_PCF_35 RBC_PCF_36 RBC_PCF_37 RBC_PCF_38 RBC_PCF_39 RBC_PCF_40 RBC_PCF_41 RBC_PCF_42 RBC_PCF_43 RBC_PCF_44 RBC_PCF_45 RBC_PCF_46 RBC_PCF_47 RBC_PCF_48;
  %local outputs stages scratch made published i name idvar bad n existing
    n_source n_good n_events n_ledger n_units n_payload n_final
    n_ldate_bad n_admbad n_ambigunits n_normgroups n_normfields
    n_normmed1 n_normmed2 n_normmed3 n_normmed4 n_normmed5 n_normmed6
    cleanup_mode cleanup_syntax cleanup_obs cleanup_replace cleanup_cc;
  %let RBC_PREPARE_OK=0; %let RBC_PREPARE_ERROR=NONE;
  %let RBC_PREPARE_STAGE=GUARDS; %let RBC_PCF_READY=0;
  %do i=1 %to 48; %let RBC_PCF_&i=NOT_CHECKED; %end;
  %let made=0; %let published=0; %let n_normgroups=0; %let n_normfields=0;
  %do i=1 %to 6; %let n_normmed&i=0; %end;
  %let outputs=canonical_events canonical_long canonical_units index_units
    event_factor_eligibility source_exclusions source_flow prepare_manifest prepare_status
    loess_prewindow flow_metrics flow_checks;
  %let stages=_rps_events _rps_long _rps_units _rps_indexunits
    _rps_factors _rps_exclusions _rps_flow _rps_manifest _rps_status
    _rps_loess_prewindow _rps_flow_metrics _rps_flow_checks;
  %let scratch=_rps_index _rps_irbad _rps_people _rps_asrc _rps_ap _rps_adm
    _rps_abadhist _rps_akey _rps_acount _rps_ie _rps_link _rps_linkgood
    _rps_linkbad _rps_profiles _rps_pconf _rps_lsrc _rps_ld _rps_ldup
    _rps_umap _rps_baseevents _rps_histstack _rps_hist _rps_hcounts
    _rps_ambprior _rps_ecountstack _rps_prior _rps_eventhistory _rps_ebad
    _rps_cats _rps_catwide _rps_payload _rps_payloadconf _rps_cfield _rps_eaccept
    _rps_normgate _rps_normalized _rps_lpsrc
    _fd_one _fd_remaining _fd_loss_person _fd_loss_event _fd_identity
    &stages;
  %if &syscc>4 %then %do; %rps_fail(FRESH_SAS_SESSION_REQUIRED); %goto finish; %end;
  %if %upcase(%superq(on_error)) ne ABORT and %upcase(%superq(on_error)) ne RETURN
    %then %do; %rps_fail(ERROR_POLICY_REQUIRED); %goto finish; %end;
  %if %superq(cohort_mode) ne development_sample and %superq(cohort_mode) ne full_cohort
    %then %do; %rps_fail(COHORT_MODE_REQUIRED); %goto finish; %end;
  %if %upcase(%superq(model_grouping)) ne PERSON and %upcase(%superq(model_grouping)) ne UNRESOLVED
    %then %do; %rps_fail(MODEL_GROUPING_OPTION_REQUIRED); %goto finish; %end;
  %if %upcase(%superq(donation_date_unit)) ne DATE and %upcase(%superq(donation_date_unit)) ne DATETIME
    %then %do; %rps_fail(DONATION_DATE_UNIT_REQUIRED); %goto finish; %end;
  %if %upcase(%superq(medication_reconciliation)) ne STRICT and
      %upcase(%superq(medication_reconciliation)) ne FLOAT_ROUNDOFF_32EPS and
      %upcase(%superq(medication_reconciliation)) ne FLOAT32_SED24_REL12
    %then %do; %rps_fail(MEDICATION_RECONCILIATION_REQUIRED); %goto finish; %end;
  %if %upcase(%superq(science_frozen)) ne YES and %upcase(%superq(science_frozen)) ne NO
    %then %do; %rps_fail(SCIENCE_FROZEN_FLAG_REQUIRED); %goto finish; %end;
  %do i=1 %to 2;
    %let idvar=%scan(run_id analysis_spec_id,&i);
    %if %length(%superq(&idvar))=0 or %length(%superq(&idvar))>64 or
        %sysfunc(prxmatch(/^[A-Za-z0-9_-]+$/,%superq(&idvar))) ne 1
      %then %do; %rps_fail(RUN_IDENTITY_REQUIRED); %goto finish; %end;
  %end;
   
  %do i=1 %to 3;
    %let idvar=%scan(input_snapshot_id code_hash config_hash,&i);
    %if %length(%superq(&idvar)) ne 64 %then %do;
      %rps_fail(PREPARATION_BINDING_REQUIRED); %goto finish;
    %end;
    %if %sysfunc(prxmatch(/^[A-Fa-f0-9]{64}$/,%superq(&idvar))) ne 1 %then %do;
      %rps_fail(PREPARATION_BINDING_REQUIRED); %goto finish;
    %end;
  %end;
  %if not %sysmacexist(rbc_capture_loess_prewindow) or not %sysmacexist(rbc_capture_preparation_flow) %then %do;
    %rps_fail(PREPARATION_SUPPLEMENT_MODULES_REQUIRED); %goto finish;
  %end;
  %if %length(%superq(outlib))>8 or not %sysfunc(nvalid(%superq(outlib),V7))
    %then %do; %rps_fail(OUTPUT_LIBRARY_REQUIRED); %goto finish; %end;
  %if %sysfunc(libref(&outlib)) ne 0 %then %do;
    %rps_fail(OUTPUT_LIBRARY_REQUIRED); %goto finish;
  %end;
  %if not %sysmacexist(rbc_derive_category_fields) %then %do;
    %rps_fail(SHARED_CATEGORY_MODULE_REQUIRED); %goto finish;
  %end;
  %rps_require(ds=&index,
    vars=StudyID PatientID TransDt Datetime Value AdmissionTime DischargeTime Age Sex WardName Abbreviation SAPS_3 Crystalloid_1 Crystalloid_24 Pressors_1 Pressors_24 Sedatives_1 Sedatives_24,
    types=N N N N N N N N C C C C N N N N N N);
  %if &RBC_PREPARE_ERROR ne NONE %then %goto finish;
  %rps_require(ds=&ledger,
    vars=StudyID Poolnum TransDt TransDate XProdType DonDate Storage DonorHb DonorSex DonorParity,
    types=N N N N C N N N N N);
  %if &RBC_PREPARE_ERROR ne NONE %then %goto finish;
  %rps_require(ds=&admissions,vars=StudyID PatientID AdmissionTime DischargeTime,types=N N C C);
  %if &RBC_PREPARE_ERROR ne NONE %then %goto finish;
  %do i=1 %to %sysfunc(countw(&outputs));
    %let name=%scan(&outputs,&i);
    %if %sysfunc(exist(&outlib..&name,DATA)) or %sysfunc(exist(&outlib..&name,VIEW))
      %then %do; %rps_fail(OUTPUT_ALREADY_EXISTS); %goto finish; %end;
  %end;
  proc sql noprint;
    select count(*) into :existing trimmed from dictionary.tables
      where libname='WORK' and (substr(upcase(memname),1,5)='_RPS_' or substr(upcase(memname),1,4)='_FD_');
  quit;
  %rps_step(SCRATCH_GUARD);
  %if &RBC_PREPARE_ERROR ne NONE %then %goto finish;
  %if &existing ne 0 %then %do; %rps_fail(SCRATCH_COLLISION); %goto finish; %end;
  %let made=1;

  data work._rps_index work._rps_irbad;
    length VitalCode $4 ReasonCode $48 ClinicalPatientID PersonKey 8;
    set &index(keep=StudyID PatientID TransDt Datetime Value AdmissionTime DischargeTime
      Age Sex WardName Abbreviation SAPS_3 Crystalloid_1 Crystalloid_24 Pressors_1 Pressors_24
      Sedatives_1 Sedatives_24 rename=(PatientID=ClinicalPatientID Age=PatientAge Sex=PatientSex
        AdmissionTime=StoredAdmissionTime DischargeTime=StoredDischargeTime));
    PersonKey=StudyID; VitalCode=''; ReasonCode='';
    select (strip(Abbreviation));
      when ('ARTm') VitalCode='ARTm'; when ('ARTs') VitalCode='ARTs';
      when ('ARTd') VitalCode='ARTd'; when ('FIO2(u)') VitalCode='FIO2';
      when ('SpO2') VitalCode='SPO2'; when ('VE(u)') VitalCode='VE';
      otherwise do;
        if strip(Abbreviation)=cats('Hj','E4'x,'rtfrekv') or
           strip(Abbreviation)=cats('Hj','C3A4'x,'rtfrekv') then VitalCode='HR';
      end;
    end;
    if cmiss(PersonKey,ClinicalPatientID,TransDt)>0 then ReasonCode='MISSING_SOURCE_EVENT_KEY';
    else if missing(VitalCode) then ReasonCode='OUTSIDE_DECLARED_OUTCOMES';
    else if missing(Datetime) then ReasonCode='MISSING_MEASUREMENT_TIME';
    else if Datetime<TransDt-43200 or Datetime>TransDt+43200 then ReasonCode='OUTSIDE_ANALYSIS_WINDOW';
    if missing(ReasonCode) then output work._rps_index;
    else output work._rps_irbad;
    drop Abbreviation;
  run;
  proc sql noprint;
    select count(*) into :n_source trimmed from &index;
     
    create table work._rps_people as select distinct StudyID from &index where not missing(StudyID);
    create table work._rps_asrc as select a.StudyID,a.PatientID,a.AdmissionTime,a.DischargeTime
      from &admissions a inner join work._rps_people p on a.StudyID=p.StudyID;
    create table work._rps_lsrc as select l.StudyID,l.Poolnum,l.TransDt,l.TransDate,
      l.DonDate,l.Storage,l.DonorHb,l.DonorSex,l.DonorParity
      from &ledger l inner join work._rps_people p on l.StudyID=p.StudyID where l.XProdType='E';
  quit;
  %rps_step(SOURCE_SCOPE);
  %if &RBC_PREPARE_ERROR ne NONE %then %goto finish;
  data work._rps_ap;
    set work._rps_asrc;
    StartDT=.; EndDT=.;
    if lengthn(strip(AdmissionTime))<=32 then StartDT=input(strip(AdmissionTime),?? anydtdtm32.);
    if lengthn(strip(DischargeTime))<=32 then EndDT=input(strip(DischargeTime),?? anydtdtm32.);
    Invalid=(cmiss(StudyID,PatientID,StartDT,EndDT)>0 or StartDT>EndDT);
    keep StudyID PatientID StartDT EndDT Invalid;
  run;
  proc sql noprint;
    create table work._rps_adm as select distinct StudyID,PatientID,StartDT,EndDT
      from work._rps_ap where Invalid=0;
    create table work._rps_abadhist as select distinct StudyID from work._rps_ap where Invalid=1;
    select count(*) into :n_admbad trimmed from work._rps_ap where Invalid=1;
    create table work._rps_akey as select PatientID from work._rps_adm
      group by PatientID having count(*) ne 1;
    select count(*) into :bad trimmed from work._rps_akey;
  quit;
  %rps_step(ADMISSION_PARSE);
  %if &RBC_PREPARE_ERROR ne NONE %then %goto finish;
  %if &bad>0 %then %do; %rps_fail(CLINICAL_EPISODE_KEY_CONFLICT); %goto finish; %end;
  proc sql;
    create table work._rps_ie as select distinct PersonKey,TransDt from work._rps_index;
    create table work._rps_acount as select e.PersonKey,e.TransDt,count(a.PatientID) as AdmissionMatches,
      min(a.PatientID) as MatchClinicalID,min(a.StartDT) as AdmissionTime,min(a.EndDT) as DischargeTime,
      max(not missing(b.StudyID)) as InvalidAdmissionHistory
      from work._rps_ie e left join work._rps_adm a on e.PersonKey=a.StudyID
        and a.StartDT<=e.TransDt and e.TransDt<=a.EndDT
      left join work._rps_abadhist b on e.PersonKey=b.StudyID
      group by e.PersonKey,e.TransDt;
    create table work._rps_link as select i.*,a.AdmissionMatches,a.MatchClinicalID,
      a.AdmissionTime,a.DischargeTime,a.InvalidAdmissionHistory
      from work._rps_index i inner join work._rps_acount a
        on i.PersonKey=a.PersonKey and i.TransDt=a.TransDt;
  quit;
  data work._rps_linkgood work._rps_linkbad;
    set work._rps_link;
    length RBC_EventKey ICUAdmissionKey $80 SAPS3_Status $16;
    ReasonCode='';
    if InvalidAdmissionHistory then ReasonCode='INVALID_ADMISSION_HISTORY';
    else if AdmissionMatches=0 then ReasonCode='NO_ADMISSION_CONTAINS_INDEX';
    else if AdmissionMatches>1 then ReasonCode='MULTIPLE_ADMISSIONS_CONTAIN_INDEX';
    else if ClinicalPatientID ne MatchClinicalID then ReasonCode='STORED_CLINICAL_ID_MISMATCH';
    else if cmiss(StoredAdmissionTime,StoredDischargeTime)>0 or StoredAdmissionTime ne AdmissionTime
      or StoredDischargeTime ne DischargeTime then ReasonCode='STORED_ADMISSION_BOUNDS_MISMATCH';
    RBC_EventKey=cats('E',put(PersonKey,hex16.),'_',put(TransDt,hex16.));
    ICUAdmissionKey=cats('A',put(PersonKey,hex16.),'_',put(ClinicalPatientID,hex16.));
    SAPS3=.;
    if missing(SAPS_3) then SAPS3_Status='MISSING';
    else if lengthn(strip(SAPS_3))<=32 and
      prxmatch('/^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)$/',strip(SAPS_3)) then do;
      SAPS3=input(strip(SAPS_3),?? best32.);
      if missing(SAPS3) then SAPS3_Status='INVALID'; else SAPS3_Status='VALID';
    end;
    else SAPS3_Status='INVALID';
    if missing(ReasonCode) then output work._rps_linkgood;
    else output work._rps_linkbad;
  run;
  proc sql noprint;
    create table work._rps_profiles as select distinct PersonKey,ClinicalPatientID,TransDt,
      RBC_EventKey,ICUAdmissionKey,AdmissionTime,DischargeTime,PatientAge,PatientSex,WardName,SAPS_3,SAPS3,SAPS3_Status
      from work._rps_linkgood;
    create table work._rps_pconf as select RBC_EventKey from work._rps_profiles
      group by RBC_EventKey having count(*) ne 1;
    select count(*) into :bad trimmed from work._rps_pconf;
  quit;
  %rps_step(INDEX_ADMISSION_LINK);
  %if &RBC_PREPARE_ERROR ne NONE %then %goto finish;
  %if &bad>0 %then %do; %rps_fail(CONFLICTING_EVENT_DESCRIPTORS); %goto finish; %end;

  data work._rps_ld;
    set work._rps_lsrc;
    length RBC_UnitKey $80 StoredLedgerDateKind $16;
    PersonKey=StudyID;
    UnitDate=datepart(TransDt);
    RBC_UnitKey=cats('U',put(PersonKey,hex16.),'_',put(UnitDate,hex16.),'_',put(Poolnum,hex16.));
    if missing(TransDate) then StoredLedgerDateKind='MISSING';
    else if TransDate=UnitDate then StoredLedgerDateKind='DATE';
    else if datepart(TransDate)=UnitDate then StoredLedgerDateKind='DATETIME';
    else StoredLedgerDateKind='INCONSISTENT';
    %if %upcase(&donation_date_unit)=DATETIME %then %do;
      if missing(DonDate) then wdy_donation=.; else wdy_donation=weekday(datepart(DonDate));
    %end;
    %else %do;
      if missing(DonDate) then wdy_donation=.; else wdy_donation=weekday(DonDate);
    %end;
    InvalidUnitKey=(cmiss(PersonKey,TransDt,Poolnum)>0 or Poolnum<1 or Poolnum ne floor(Poolnum));
    format _numeric_ best32.;
  run;
  proc sql noprint;
    select count(*) into :n_ledger trimmed from work._rps_ld;
    select count(*) into :bad trimmed from work._rps_ld where InvalidUnitKey;
    select count(*) into :n_ldate_bad trimmed from work._rps_ld
      where StoredLedgerDateKind in ('MISSING','INCONSISTENT');
  quit;
  %rps_step(LEDGER_KEY_DERIVATION);
  %if &RBC_PREPARE_ERROR ne NONE %then %goto finish;
  %if &bad>0 %then %do; %rps_fail(INVALID_PHYSICAL_UNIT_KEY); %goto finish; %end;
  proc sort data=work._rps_ld nodupkey; by _all_; run;
  proc sql noprint;
    create table work._rps_ldup as select RBC_UnitKey from work._rps_ld
      group by RBC_UnitKey having count(*) ne 1;
    select count(*) into :bad trimmed from work._rps_ldup;
    select count(*) into :n_units trimmed from work._rps_ld;
  quit;
  %rps_step(LEDGER_EXACT_RECONCILIATION);
  %if &RBC_PREPARE_ERROR ne NONE %then %goto finish;
  %if &bad>0 %then %do; %rps_fail(CONFLICTING_PHYSICAL_UNIT_KEY); %goto finish; %end;
  proc sql;
    create table work._rps_umap as select u.RBC_UnitKey,count(a.PatientID) as UnitAdmissionMatches,
      min(a.PatientID) as MatchClinicalID,min(a.StartDT) as AdmissionTime,min(a.EndDT) as DischargeTime
      from work._rps_ld u left join work._rps_adm a on u.PersonKey=a.StudyID
        and a.StartDT<=u.TransDt and u.TransDt<=a.EndDT group by u.RBC_UnitKey;
    create table work._rps_units as select u.*,m.UnitAdmissionMatches,m.MatchClinicalID,
      m.AdmissionTime,m.DischargeTime from work._rps_ld u inner join work._rps_umap m
        on u.RBC_UnitKey=m.RBC_UnitKey;
  quit;
  data work._rps_units;
    set work._rps_units;
    length ICUAdmissionKey $80 UnitAdmissionStatus $24;
    ClinicalPatientID=.; ICUAdmissionKey='';
    if UnitAdmissionMatches=1 then do;
      ClinicalPatientID=MatchClinicalID;
      ICUAdmissionKey=cats('A',put(PersonKey,hex16.),'_',put(ClinicalPatientID,hex16.));
      UnitAdmissionStatus='UNIQUE';
    end;
    else do;
      AdmissionTime=.; DischargeTime=.;
      if UnitAdmissionMatches=0 then UnitAdmissionStatus='NO_MATCH';
      else UnitAdmissionStatus='AMBIGUOUS';
    end;
    drop MatchClinicalID InvalidUnitKey;
  run;
  %rps_step(UNIT_ADMISSION_ASSIGNMENT);
  %if &RBC_PREPARE_ERROR ne NONE %then %goto finish;

  data work._rps_histstack;
    length RBC_EventKey $80;
    set work._rps_units(in=u keep=PersonKey TransDt)
        work._rps_profiles(in=e keep=PersonKey TransDt RBC_EventKey);
    if e then RowType=0;
    else do; RowType=1; RBC_EventKey=''; end;
  run;
  proc sort data=work._rps_histstack; by PersonKey TransDt RowType; run;
  data work._rps_hist(keep=RBC_EventKey PreviousUnitTime);
    set work._rps_histstack; by PersonKey TransDt RowType;
    retain PreviousUnitTime;
    if first.PersonKey then PreviousUnitTime=.;
    if RowType=0 then output;
    else PreviousUnitTime=TransDt;
  run;
  data work._rps_ecountstack;
    length RBC_EventKey $80;
    set work._rps_units(in=u where=(UnitAdmissionMatches=1)
          keep=PersonKey TransDt ICUAdmissionKey UnitAdmissionMatches)
        work._rps_profiles(in=e keep=PersonKey TransDt ICUAdmissionKey RBC_EventKey);
    if e then RowType=0;
    else do; RowType=1; RBC_EventKey=''; end;
  run;
  proc sort data=work._rps_ecountstack; by PersonKey ICUAdmissionKey TransDt RowType; run;
  data work._rps_prior(keep=RBC_EventKey RBC_Count);
    set work._rps_ecountstack; by PersonKey ICUAdmissionKey TransDt RowType;
    retain RBC_Count;
    if first.ICUAdmissionKey then RBC_Count=0;
    if RowType=0 then output; else RBC_Count+1;
  run;
  proc sql;
    create table work._rps_hcounts as select e.RBC_EventKey,count(u.RBC_UnitKey) as NIndexUnits
      from work._rps_profiles e left join work._rps_units u
        on e.PersonKey=u.PersonKey and e.TransDt=u.TransDt group by e.RBC_EventKey;
    create table work._rps_ambprior as select e.RBC_EventKey,count(u.RBC_UnitKey) as NAmbiguousPriorUnits
      from work._rps_profiles e left join work._rps_units u on e.PersonKey=u.PersonKey
        and u.TransDt>=e.AdmissionTime and u.TransDt<e.TransDt and u.UnitAdmissionMatches ne 1
      group by e.RBC_EventKey;
    create table work._rps_eventhistory as select e.*,h.PreviousUnitTime,p.RBC_Count,
      n.NIndexUnits,a.NAmbiguousPriorUnits from work._rps_profiles e
      inner join work._rps_hist h on e.RBC_EventKey=h.RBC_EventKey
      inner join work._rps_prior p on e.RBC_EventKey=p.RBC_EventKey
      inner join work._rps_hcounts n on e.RBC_EventKey=n.RBC_EventKey
      inner join work._rps_ambprior a on e.RBC_EventKey=a.RBC_EventKey;
  quit;
  data work._rps_eaccept work._rps_ebad;
    set work._rps_eventhistory;
    length ReasonCode $48 WardCode $256;
    ReasonCode=''; WardCode=WardName;
    if NIndexUnits=0 then ReasonCode='INDEX_EVENT_ABSENT_FROM_LEDGER';
    else if NAmbiguousPriorUnits>0 then ReasonCode='AMBIGUOUS_PRIOR_UNIT_ADMISSION';
    else if not missing(PreviousUnitTime) and PreviousUnitTime>=TransDt-43200
      then ReasonCode='PREVIOUS_RBC_WITHIN_OR_AT_MINUS12H';
    ICU_time=(TransDt-AdmissionTime)/60;
    if missing(ReasonCode) then output work._rps_eaccept; else output work._rps_ebad;
  run;
  proc sql noprint;
    select count(*) into :n_final trimmed from work._rps_eaccept;
    create table work._rps_indexunits as select u.*,e.RBC_EventKey from work._rps_units u
      inner join work._rps_eaccept e on u.PersonKey=e.PersonKey and u.TransDt=e.TransDt;
  quit;
  %rps_step(PRIOR_HISTORY_AND_INDEX_ELIGIBILITY);
  %if &RBC_PREPARE_ERROR ne NONE %then %goto finish;
  %if &n_final=0 %then %do; %rps_fail(EMPTY_ELIGIBLE_COHORT); %goto finish; %end;

  data work._rps_cats;
    set work._rps_indexunits;
    %rbc_derive_category_fields;
    ValidSex=(DonorSex in (1,2)); ValidWeekday=(wdy_donation in (1,2,3,4,5,6,7));
  run;
  proc sql;
    create table work._rps_catwide as select PersonKey,RBC_EventKey,count(*) as NUnits,
      count(DonorHb_Cat) as KnownHb,min(DonorHb_Cat) as MinHb,max(DonorHb_Cat) as MaxHb,
      count(Storage_Cat) as KnownStorage,min(Storage_Cat) as MinStorage,max(Storage_Cat) as MaxStorage,
      sum(ValidSex) as KnownSex,min(DonorSex) as MinSex,max(DonorSex) as MaxSex,
      sum(DonorSex=2) as NFemale,count(DonorParity_Female) as KnownParity,
      min(DonorParity_Female) as MinParity,max(DonorParity_Female) as MaxParity,
      sum(ValidWeekday) as KnownWeekday,min(wdy_donation) as MinWeekday,max(wdy_donation) as MaxWeekday
      from work._rps_cats group by PersonKey,RBC_EventKey;
  quit;
  data work._rps_factors(keep=PersonKey RBC_EventKey Factor CategoryCode Eligible ReasonCode NUnits)
       work._rps_catwide(keep=PersonKey RBC_EventKey NUnits DonorHb_Cat Storage_Cat DonorSex DonorParity_Female DonorParity wdy_donation);
    set work._rps_catwide;
    length Factor $32 ReasonCode $48;
    DonorHb_Cat=.; Storage_Cat=.; DonorSex=.; DonorParity_Female=.; DonorParity=.; wdy_donation=.;
    Factor='MAIN'; Eligible=1; CategoryCode=1; ReasonCode='ALL_CANONICAL_EVENTS'; output work._rps_factors;
    Factor='DonorHb_Cat'; Eligible=(KnownHb=NUnits and MinHb=MaxHb);
    CategoryCode=.; ReasonCode='UNKNOWN_OR_INVALID_UNIT_CATEGORY';
    if Eligible then do; CategoryCode=MinHb; DonorHb_Cat=MinHb; ReasonCode='ALL_UNITS_SAME_KNOWN_CATEGORY'; end;
    else if KnownHb=NUnits then ReasonCode='MIXED_UNIT_CATEGORIES';
    output work._rps_factors;
    Factor='Storage_Cat'; Eligible=(KnownStorage=NUnits and MinStorage=MaxStorage);
    CategoryCode=.; ReasonCode='UNKNOWN_OR_INVALID_UNIT_CATEGORY';
    if Eligible then do; CategoryCode=MinStorage; Storage_Cat=MinStorage; ReasonCode='ALL_UNITS_SAME_KNOWN_CATEGORY'; end;
    else if KnownStorage=NUnits then ReasonCode='MIXED_UNIT_CATEGORIES';
    output work._rps_factors;
    Factor='DonorSex'; Eligible=(KnownSex=NUnits and MinSex=MaxSex);
    CategoryCode=.; ReasonCode='UNKNOWN_OR_INVALID_UNIT_CATEGORY';
    if Eligible then do; CategoryCode=MinSex; DonorSex=MinSex; ReasonCode='ALL_UNITS_SAME_KNOWN_CATEGORY'; end;
    else if KnownSex=NUnits then ReasonCode='MIXED_UNIT_CATEGORIES';
    output work._rps_factors;
    Factor='DonorParity_Female'; Eligible=(NFemale=NUnits and KnownParity=NUnits and MinParity=MaxParity);
    CategoryCode=.; ReasonCode='NONFEMALE_OR_UNKNOWN_DONOR';
    if Eligible then do; CategoryCode=MinParity; DonorParity_Female=MinParity; DonorParity=MinParity; ReasonCode='ALL_UNITS_SAME_KNOWN_CATEGORY'; end;
    else if NFemale=NUnits then do;
      if KnownParity<NUnits then ReasonCode='UNKNOWN_OR_INVALID_UNIT_CATEGORY'; else ReasonCode='MIXED_UNIT_CATEGORIES';
    end;
    output work._rps_factors;
    Factor='wdy_donation'; Eligible=(KnownWeekday=NUnits and MinWeekday=MaxWeekday);
    CategoryCode=.; ReasonCode='UNKNOWN_OR_INVALID_UNIT_CATEGORY';
    if Eligible then do; CategoryCode=MinWeekday; wdy_donation=MinWeekday; ReasonCode='ALL_UNITS_SAME_KNOWN_CATEGORY'; end;
    else if KnownWeekday=NUnits then ReasonCode='MIXED_UNIT_CATEGORIES';
    output work._rps_factors;
    output work._rps_catwide;
  run;
  proc sql;
    create table work._rps_events as select e.*,c.DonorHb_Cat,c.Storage_Cat,c.DonorSex,
      c.DonorParity_Female,c.DonorParity,c.wdy_donation from work._rps_eaccept e
      inner join work._rps_catwide c on e.RBC_EventKey=c.RBC_EventKey;
    create table work._rps_payload as select distinct i.PersonKey,i.ClinicalPatientID,i.RBC_EventKey,
      i.ICUAdmissionKey,i.TransDt,i.Datetime,i.VitalCode,i.Value,i.PatientAge,i.PatientSex,i.WardName,
      i.Crystalloid_1,i.Crystalloid_24,i.Pressors_1,i.Pressors_24,i.Sedatives_1,i.Sedatives_24,
      e.AdmissionTime,e.DischargeTime,e.ICU_time,e.RBC_Count,
      e.DonorHb_Cat,e.Storage_Cat,e.DonorSex,e.DonorParity_Female,e.DonorParity,e.wdy_donation
      from work._rps_linkgood i inner join work._rps_events e on i.RBC_EventKey=e.RBC_EventKey;
    create table work._rps_payloadconf as select RBC_EventKey,VitalCode,Datetime from work._rps_payload
      group by RBC_EventKey,VitalCode,Datetime having count(*) ne 1;
  quit;
  proc sql noprint;
    select count(*) into :bad trimmed from work._rps_payloadconf;
    select count(*) into :n_payload trimmed from work._rps_payload;
  quit;
  %rps_step(FACTOR_AND_MEASUREMENT_RECONCILIATION);
  %if &RBC_PREPARE_ERROR ne NONE %then %goto finish;
  %if &bad>0 %then %do;

    proc sql;
      create table work._rps_cfield as select RBC_EventKey,VitalCode,Datetime,
        count(distinct put(Value,hex16.)) as n1,
        count(distinct case when not missing(Value) then put(Value,hex16.) else '' end) as v1,
        min(missing(Value)) as lo1,
        max(missing(Value)) as hi1,
        count(distinct put(Crystalloid_1,hex16.)) as n2,
        count(distinct case when not missing(Crystalloid_1) then put(Crystalloid_1,hex16.) else '' end) as v2,
        min(missing(Crystalloid_1)) as lo2,
        max(missing(Crystalloid_1)) as hi2,
        count(distinct put(Crystalloid_24,hex16.)) as n3,
        count(distinct case when not missing(Crystalloid_24) then put(Crystalloid_24,hex16.) else '' end) as v3,
        min(missing(Crystalloid_24)) as lo3,
        max(missing(Crystalloid_24)) as hi3,
        count(distinct put(Pressors_1,hex16.)) as n4,
        count(distinct case when not missing(Pressors_1) then put(Pressors_1,hex16.) else '' end) as v4,
        min(missing(Pressors_1)) as lo4,
        max(missing(Pressors_1)) as hi4,
        count(distinct put(Pressors_24,hex16.)) as n5,
        count(distinct case when not missing(Pressors_24) then put(Pressors_24,hex16.) else '' end) as v5,
        min(missing(Pressors_24)) as lo5,
        max(missing(Pressors_24)) as hi5,
        count(distinct put(Sedatives_1,hex16.)) as n6,
        count(distinct case when not missing(Sedatives_1) then put(Sedatives_1,hex16.) else '' end) as v6,
        min(missing(Sedatives_1)) as lo6,
        max(missing(Sedatives_1)) as hi6,
        count(distinct put(Sedatives_24,hex16.)) as n7,
        count(distinct case when not missing(Sedatives_24) then put(Sedatives_24,hex16.) else '' end) as v7,
        min(missing(Sedatives_24)) as lo7,
        max(missing(Sedatives_24)) as hi7,
        min(Crystalloid_1) as mn2,
        max(Crystalloid_1) as mx2,
        max(case when Crystalloid_1=0 then 1 else 0 end) as z2,
        max(case when Crystalloid_1>0 then 1 else 0 end) as p2,
        min(Crystalloid_24) as mn3,
        max(Crystalloid_24) as mx3,
        max(case when Crystalloid_24=0 then 1 else 0 end) as z3,
        max(case when Crystalloid_24>0 then 1 else 0 end) as p3,
        min(Pressors_1) as mn4,
        max(Pressors_1) as mx4,
        max(case when Pressors_1=0 then 1 else 0 end) as z4,
        max(case when Pressors_1>0 then 1 else 0 end) as p4,
        min(Pressors_24) as mn5,
        max(Pressors_24) as mx5,
        max(case when Pressors_24=0 then 1 else 0 end) as z5,
        max(case when Pressors_24>0 then 1 else 0 end) as p5,
        min(Sedatives_1) as mn6,
        max(Sedatives_1) as mx6,
        max(case when Sedatives_1=0 then 1 else 0 end) as z6,
        max(case when Sedatives_1>0 then 1 else 0 end) as p6,
        min(Sedatives_24) as mn7,
        max(Sedatives_24) as mx7,
        max(case when Sedatives_24=0 then 1 else 0 end) as z7,
        max(case when Sedatives_24>0 then 1 else 0 end) as p7
      from work._rps_payload group by RBC_EventKey,VitalCode,Datetime having count(*)>1;
    quit;
    data _null_;
      set work._rps_cfield end=last;
      array n[7] n1-n7; array v[7] v1-v7;
      array lo[7] lo1-lo7; array hi[7] hi1-hi7;
      array conflicts[7] _temporary_ (7*0);
      array mixed[7] _temporary_ (7*0);
      array unequal[7] _temporary_ (7*0);
      array mn[6] mn2-mn7; array mx[6] mx2-mx7;
      array z[6] z2-z7; array p[6] p2-p7;
      array near_eps[6] _temporary_ (6*1);
      array near12[6] _temporary_ (6*1);
      array near8[6] _temporary_ (6*1);
      array zeropos[6] _temporary_ (6*0);
      array flags[48] _temporary_;
      length Status $4;
      do j=1 to 7;
        conflicts[j]=max(conflicts[j],n[j]>1);
        mixed[j]=max(mixed[j],lo[j] ne hi[j]);
        unequal[j]=max(unequal[j],v[j]>1);
      end;

      do j=1 to 6;
        k=j+1;
        if n[k]>1 then do;
          zeropos[j]=max(zeropos[j],z[j]=1 and p[j]=1);
          if hi[k]=1 or missing(mn[j]) or missing(mx[j]) then do;
            near_eps[j]=0; near12[j]=0; near8[j]=0;
          end;
          else do;
            magnitude=max(abs(mn[j]),abs(mx[j]));
            if magnitude=0 then relative_gap=0;
            else if mn[j]<0 and mx[j]>0 then relative_gap=abs(mn[j]/magnitude)+abs(mx[j]/magnitude);
            else relative_gap=(mx[j]-mn[j])/magnitude;
            near_eps[j]=min(near_eps[j],relative_gap<=32*constant('MACEPS'));
            near12[j]=min(near12[j],relative_gap<=1e-12);
            near8[j]=min(near8[j],relative_gap<=1e-8);
          end;
        end;
      end;
      if last then do;
        AnyMedication=0; AnyNonmissingDifference=0; AnyConflict=0;
        do j=1 to 7;
          flags[j]=conflicts[j]; flags[j+7]=mixed[j]; flags[j+14]=unequal[j];
          AnyConflict=max(AnyConflict,conflicts[j]);
          AnyNonmissingDifference=max(AnyNonmissingDifference,unequal[j]);
          if j>1 then AnyMedication=max(AnyMedication,conflicts[j]);
        end;
        flags[22]=(conflicts[1]=1 and AnyMedication=0);
        flags[23]=(conflicts[1]=0 and AnyMedication=1);
        flags[24]=(AnyConflict=1 and AnyNonmissingDifference=0);
        do j=1 to 6;
          flags[24+j]=(conflicts[j+1]=1 and near_eps[j]=1);
          flags[30+j]=(conflicts[j+1]=1 and near12[j]=1);
          flags[36+j]=(conflicts[j+1]=1 and near8[j]=1);
          flags[42+j]=zeropos[j];
        end;
        do j=1 to 48;
          if flags[j]=1 then Status='PASS'; else Status='FAIL';
          call symputx(cats('RBC_PCF_',j),Status,'G');
        end;
      end;
    run;
    %rps_step(FACTOR_AND_MEASUREMENT_RECONCILIATION);
    %if &RBC_PREPARE_ERROR ne NONE %then %goto finish;
    %let RBC_PCF_READY=1;
    %if %upcase(&medication_reconciliation)=STRICT %then %do;
      %rps_fail(CONFLICTING_ANALYSIS_PAYLOAD); %goto finish;
    %end;

    data work._rps_normgate;
      set work._rps_cfield;
      array n[7] n1-n7; array hi[7] hi1-hi7;
      array mn[6] mn2-mn7; array mx[6] mx2-mx7;
      Allowed=(n1=1); NormalizedFields=0;
      do j=1 to 6;
        if n[j+1]>1 then do;
          NormalizedFields+1;
          if hi[j+1]=1 or missing(mn[j]) or missing(mx[j]) then Allowed=0;
          else if not ((mn[j]>0 and mx[j]>0) or (mn[j]<0 and mx[j]<0) or
              (mn[j]=0 and mx[j]=0)) then Allowed=0;
          else do;
            Magnitude=max(abs(mn[j]),abs(mx[j]));
            Limit=32*constant('MACEPS')*Magnitude;
            Gap=mx[j]-mn[j];
            %if %upcase(&medication_reconciliation)=FLOAT32_SED24_REL12 %then %do;
              if j=6 then do;
                if Magnitude>0 then RelativeGap=Gap/Magnitude;
                else if Gap=0 then RelativeGap=0;
                else RelativeGap=.;
                if missing(RelativeGap) or RelativeGap>1e-12 then Allowed=0;
              end;
              else if missing(Limit) or missing(Gap) or Gap>Limit then Allowed=0;
            %end;
            %else %do;
              if missing(Limit) or missing(Gap) or Gap>Limit then Allowed=0;
            %end;
          end;
        end;
      end;
      drop j Magnitude Limit Gap;
      %if %upcase(&medication_reconciliation)=FLOAT32_SED24_REL12 %then %do;
        drop RelativeGap;
      %end;
    run;
    proc sql noprint;
      select coalesce(sum(Allowed ne 1),0),coalesce(sum(NormalizedFields>0),0),
        coalesce(sum(NormalizedFields),0),
        coalesce(sum(n2>1),0),coalesce(sum(n3>1),0),coalesce(sum(n4>1),0),
        coalesce(sum(n5>1),0),coalesce(sum(n6>1),0),coalesce(sum(n7>1),0)
        into :bad trimmed,:n_normgroups trimmed,:n_normfields trimmed,
        :n_normmed1 trimmed,:n_normmed2 trimmed,:n_normmed3 trimmed,
        :n_normmed4 trimmed,:n_normmed5 trimmed,:n_normmed6 trimmed
      from work._rps_normgate;
    quit;
    %rps_step(FACTOR_AND_MEASUREMENT_RECONCILIATION);
    %if &RBC_PREPARE_ERROR ne NONE %then %goto finish;
    %if &bad>0 %then %do; %rps_fail(CONFLICTING_ANALYSIS_PAYLOAD); %goto finish; %end;
    proc sql;
      create table work._rps_normalized as select distinct
        i.PersonKey,i.ClinicalPatientID,i.RBC_EventKey,i.ICUAdmissionKey,i.TransDt,
        i.Datetime,i.VitalCode,i.Value,i.PatientAge,i.PatientSex,i.WardName,
        case when c.n2>1 then c.mn2 else i.Crystalloid_1 end as Crystalloid_1,
        case when c.n3>1 then c.mn3 else i.Crystalloid_24 end as Crystalloid_24,
        case when c.n4>1 then c.mn4 else i.Pressors_1 end as Pressors_1,
        case when c.n5>1 then c.mn5 else i.Pressors_24 end as Pressors_24,
        case when c.n6>1 then c.mn6 else i.Sedatives_1 end as Sedatives_1,
        case when c.n7>1 then c.mn7 else i.Sedatives_24 end as Sedatives_24,
        i.AdmissionTime,i.DischargeTime,i.ICU_time,i.RBC_Count,
        i.DonorHb_Cat,i.Storage_Cat,i.DonorSex,i.DonorParity_Female,i.DonorParity,i.wdy_donation
      from work._rps_payload i left join work._rps_normgate c
        on i.RBC_EventKey=c.RBC_EventKey and i.VitalCode=c.VitalCode and i.Datetime=c.Datetime;
      create table work._rps_payloadconf as select RBC_EventKey,VitalCode,Datetime
        from work._rps_normalized group by RBC_EventKey,VitalCode,Datetime having count(*) ne 1;
    quit;
    proc sql noprint; select count(*) into :bad trimmed from work._rps_payloadconf; quit;
    %rps_step(FACTOR_AND_MEASUREMENT_RECONCILIATION);
    %if &RBC_PREPARE_ERROR ne NONE %then %goto finish;
    %if &bad>0 %then %do; %rps_fail(CONFLICTING_ANALYSIS_PAYLOAD); %goto finish; %end;
  %end;
  data work._rps_long;
    %if &n_normgroups>0 %then %do; set work._rps_normalized; %end;
    %else %do; set work._rps_payload; %end;
    TimeFromTransfusion=(Datetime-TransDt)/60;
    if missing(Sedatives_1) then Sedatives_1_bin=Sedatives_1; else Sedatives_1_bin=(Sedatives_1>0);
    if missing(Sedatives_24) then Sedatives_24_bin=Sedatives_24; else Sedatives_24_bin=(Sedatives_24>0);
    PatientID=.;
    %if %upcase(&model_grouping)=PERSON %then %do; PatientID=PersonKey; %end;
  run;
  proc sql;
    create table work._rps_exclusions as
      select 'SOURCE_ROW_ELIGIBILITY' as Stage length=40,'ANALYSIS_ROWS' as CountingUnit length=24,
        ReasonCode,count(*) as Count from work._rps_irbad group by ReasonCode
      union all select 'ADMISSION_LINK','ANALYSIS_ROWS',ReasonCode,count(*)
        from work._rps_linkbad group by ReasonCode
      union all select 'HISTORY_ELIGIBILITY','CLINICAL_EVENTS',ReasonCode,count(*)
        from work._rps_ebad group by ReasonCode;
    create table work._rps_flow as
      select 'SOURCE_INDEX_ROWS' as Stage length=40,'ANALYSIS_ROWS' as CountingUnit length=24,&n_source as Count
        from work._rps_people(obs=1)
      union all select 'ROW_ELIGIBLE','ANALYSIS_ROWS',count(*) from work._rps_index
      union all select 'DISTINCT_SOURCE_EVENTS','CLINICAL_EVENTS',count(*) from work._rps_ie
      union all select 'ADMISSION_ACCEPTED_ROWS','ANALYSIS_ROWS',count(*) from work._rps_linkgood
      union all select 'ADMISSION_ACCEPTED_EVENTS','CLINICAL_EVENTS',count(*) from work._rps_profiles
      union all select 'HISTORY_ACCEPTED_EVENTS','CLINICAL_EVENTS',count(*) from work._rps_events
      union all select 'CANONICAL_RECONCILED_ROWS','ANALYSIS_ROWS',count(*) from work._rps_long
      union all select 'RBC_LEDGER_SOURCE_ROWS','LEDGER_ROWS',&n_ledger from work._rps_people(obs=1)
      union all select 'RBC_LEDGER_UNIQUE_UNITS','PHYSICAL_UNITS',count(*) from work._rps_units
      union all select 'LINKED_INDEX_UNITS','PHYSICAL_UNITS',count(*) from work._rps_indexunits;
  quit;
  data work._rps_manifest;
    length MappingEvidence ModelGroupingEvidence $40 AdmissionPolicy $64 ConcurrentPolicy $80
      UnitKeyDefinition $80 PriorUnitDefinition $80 IndexHistoryDefinition $80
      LedgerCoverage MedicationEncoding NativeOutcomeUnits ScientificFreeze $32
      DonationDateUnit $8 RuleApproval $32 MeasurementReconciliation $80
      MedicationReconciliation $24 MedicationNormalizationRule $80
      AdmissionTimeDateStyle $8;
    MappingEvidence='CODE_TRACE_SUPPORTED';

    AdmissionTimeDateStyle=upcase(getoption('DATESTYLE'));
    ModelGroupingEvidence=upcase(symget('model_grouping'));
    AdmissionPolicy='ONE_CONTAINING_ADMISSION_AND_STORED_CLINICAL_ID_MATCH';
    ConcurrentPolicy='ONE_MAIN_EVENT_FACTOR_ALL_UNITS_KNOWN_SAME_CATEGORY';
    UnitKeyDefinition='STUDYID_DATEPART_TRANSDT_POOLNUM_EXACT_NUMERIC';
    PriorUnitDefinition='STRICT_EARLIER_RECORDED_UNITS_SAME_UNIQUE_ICU_ADMISSION';
    IndexHistoryDefinition='NO_EARLIER_RECORDED_RBC_OR_PREVIOUS_TIME_LT_INDEX_MINUS43200';
    LedgerCoverage='UNRESOLVED'; MedicationEncoding='INHERITED_UNRESOLVED';
    NativeOutcomeUnits='UNRESOLVED'; ScientificFreeze='NOT_READY_FOR_FULL_RUN';
    %if %superq(cohort_mode)=full_cohort and %upcase(%superq(science_frozen))=YES %then %do;
      ScientificFreeze='ROOT_RECORDED_FREEZE';
    %end;
    DonationDateUnit=upcase(symget('donation_date_unit')); RuleApproval='DONATION_DATE_RULE_APPROVED';
    MeasurementReconciliation='EXACT_NON_DONOR_PAYLOAD_ONLY_CONFLICTS_REJECTED';
    MedicationReconciliation=upcase(symget('medication_reconciliation'));
    MedicationNormalizationRule='NONE_STRICT_EXACT';
    if MedicationReconciliation='FLOAT_ROUNDOFF_32EPS' then do;
      MeasurementReconciliation='EXACT_VALUE_ROUNDOFF_NORMALIZED_MEDICATION_FULL_PAYLOAD_RECHECKED';
      MedicationNormalizationRule='DETERMINISTIC_MIN_WITHIN_32_MACHINE_EPS_SAME_MISSING_ZERO_SIGN_CLASS';
    end;
    else if MedicationReconciliation='FLOAT32_SED24_REL12' then do;
      MeasurementReconciliation='EXACT_VALUE_BOUNDED_MEDICATION_FULL_PAYLOAD_RECHECKED';
      MedicationNormalizationRule='MIN_FIRST5_32EPS_SED24_REL1E12_SAME_MISSING_ZERO_SIGN_CLASS';
    end;
    NormalizationMeasurementCount=&n_normgroups;
    NormalizationFieldCount=&n_normfields;
    Normalized_Crystalloid_1=&n_normmed1; Normalized_Crystalloid_24=&n_normmed2;
    Normalized_Pressors_1=&n_normmed3; Normalized_Pressors_24=&n_normmed4;
    Normalized_Sedatives_1=&n_normmed5; Normalized_Sedatives_24=&n_normmed6;
    NormalizationRelativeBound=32*constant('MACEPS');
     
    if MedicationReconciliation='FLOAT32_SED24_REL12' then NormalizationRelativeBound=1e-12;
    OriginalDistinctPayloadRows=&n_payload;
  run;
  data work._rps_status;
    length Predicate $64 Status $16;
    Predicate='CANONICAL_COHORT_NONEMPTY'; Status='PASS'; output;
    Predicate='ONE_MAIN_EVENT_PER_PERSON_TIME'; Status='PASS'; output;
    Predicate='FACTOR_ALL_UNIT_AGREEMENT_ENFORCED'; Status='PASS'; output;
    Predicate='LOGICAL_MEASUREMENT_KEYS_UNIQUE'; Status='PASS'; output;
    Predicate='PRIOR_INDEX_TIES_EXCLUDED'; Status='PASS'; output;
    Predicate='STRICT_MINUS12H_ELIGIBILITY_APPLIED'; Status='PASS'; output;
    Predicate='MEDICATION_MISSINGNESS_PRESERVED'; Status='PASS'; output;
    Predicate='MEDICATION_ROUNDOFF_POLICY_CHECKED'; Status='PASS'; output;
    Predicate='STORED_LEDGER_DATE_COMPATIBLE'; if &n_ldate_bad=0 then Status='PASS'; else Status='FAIL'; output;
    Predicate='MODEL_PERSON_ALIAS_CONFIGURED';
    %if %upcase(&model_grouping)=PERSON %then %do; Status='PASS'; %end;
    %else %do; Status='NOT_CHECKED'; %end;
    output;
    Predicate='LEDGER_ASCERTAINMENT_COVERAGE'; Status='UNRESOLVED'; output;
    Predicate='HISTORY_LOWER_COVERAGE_BOUNDARY'; Status='UNRESOLVED'; output;
    Predicate='INHERITED_MEDICATION_ENCODING'; Status='UNRESOLVED'; output;
    Predicate='NATIVE_OUTCOME_UNIT_SEMANTICS'; Status='UNRESOLVED'; output;
    Predicate='DONATION_DATE_UNIT_SEMANTICS'; Status='UNRESOLVED'; output;
    Predicate='FULL_RUN_SCIENTIFIC_FREEZE';
    %if %superq(cohort_mode)=full_cohort and %upcase(%superq(science_frozen))=YES %then %do; Status='ROOT_RECORDED'; %end;
    %else %do; Status='UNRESOLVED'; %end;
    output;
  run;
  %rps_step(CANDIDATE_METADATA);
  %if &RBC_PREPARE_ERROR ne NONE %then %goto finish;

  %rbc_capture_loess_prewindow(run_id=&run_id,input_snapshot_id=&input_snapshot_id,
    code_hash=&code_hash,config_hash=&config_hash);
  %if &RBC_PREWINDOW_OK ne 1 %then %do;
    %rps_fail(PREWINDOW_&RBC_PREWINDOW_ERROR); %goto finish;
  %end;
  %rbc_capture_preparation_flow(outlib=WORK,metrics=_rps_flow_metrics,checks=_rps_flow_checks,
    run_id=&run_id,input_snapshot_id=&input_snapshot_id,code_hash=&code_hash,config_hash=&config_hash);
  %if &RBC_FLOW_OK ne 1 %then %do;
    %rps_fail(FLOW_&RBC_FLOW_ERROR); %goto finish;
  %end;
  %rps_step(PREPARATION_SUPPLEMENT_STAGED);
  %if &RBC_PREPARE_ERROR ne NONE %then %goto finish;
  %let published=1;
  %do i=1 %to %sysfunc(countw(&outputs));
    %let name=%scan(&outputs,&i);
    data &outlib..&name;
      length RunId AnalysisSpecId $64 CohortMode $24 PopulationId $32 DisclosureStatus $24 DataScope $64;
      set work.%scan(&stages,&i);
      RunId=symget('run_id'); AnalysisSpecId=symget('analysis_spec_id');
      CohortMode=symget('cohort_mode'); PopulationId='PRIMARY'; DisclosureStatus='PRIVATE_UNREVIEWED';
      %if &name=loess_prewindow %then %do;
        DataScope='PRIMARY_AVAILABLE_SOURCE_ROWS_PREWINDOW';
      %end;
      %else %if &name=canonical_units %then %do;
        PopulationId='SOURCE_INDEX_PERSON_HISTORY'; DataScope='ALL_SCOPED_RBC_HISTORY_NOT_ONLY_ELIGIBLE_INDEX_UNITS';
      %end;
      %else %if &name=canonical_events or &name=canonical_long or &name=index_units or &name=event_factor_eligibility %then %do;
        DataScope='PRIMARY_ELIGIBLE_CANONICAL_EVENTS';
      %end;
      %else %do; DataScope='PREPARATION_FROM_SOURCE_INDEX_PERSONS'; %end;
      format _numeric_ best32.;
    run;
    %rps_step(OUTPUT_WRITE);
    %if &RBC_PREPARE_ERROR ne NONE %then %goto finish;
  %end;
  %let RBC_PREPARE_OK=1; %let RBC_PREPARE_STAGE=CANONICAL_CANDIDATE_BUILT;
%finish:

  %let cleanup_mode=0;
  %if &made=1 or &published=1 %then %do;
    %let cleanup_mode=1;
    %let cleanup_syntax=%sysfunc(getoption(syntaxcheck,keyword));
    %let cleanup_obs=%sysfunc(getoption(obs,keyword));
    %let cleanup_replace=%sysfunc(getoption(replace,keyword));
    %let cleanup_cc=&syscc;
    %if &syscc>4 or &syserr>4 %then %do;
      %let RBC_PREPARE_OK=0;
      %if &RBC_PREPARE_ERROR=NONE %then %rps_fail(SAS_FAILURE_BEFORE_CLEANUP);
    %end;
    options nosyntaxcheck;
  %end;
  %if &made=1 %then %do;
    proc datasets library=work nolist nowarn; delete &scratch; quit;
    %if &syscc>4 or &syserr>4 %then %do;
      %let RBC_PREPARE_OK=0;
      %if &RBC_PREPARE_ERROR=NONE %then %rps_fail(SCRATCH_CLEANUP_FAILED);
    %end;
    %do i=1 %to %sysfunc(countw(&scratch));
      %if %sysfunc(exist(work.%scan(&scratch,&i),DATA)) or
          %sysfunc(exist(work.%scan(&scratch,&i),VIEW)) %then %rps_fail(SCRATCH_CLEANUP_FAILED);
    %end;
  %end;
  %if &published=1 and &RBC_PREPARE_OK ne 1 %then %do;
    proc datasets library=&outlib nolist nowarn; delete &outputs; quit;
    %do i=1 %to %sysfunc(countw(&outputs));
      %if %sysfunc(exist(&outlib..%scan(&outputs,&i),DATA)) or
          %sysfunc(exist(&outlib..%scan(&outputs,&i),VIEW)) %then %rps_fail(OUTPUT_ROLLBACK_FAILED);
    %end;
  %end;
  %if &cleanup_mode=1 %then %do;
    options &cleanup_syntax &cleanup_obs &cleanup_replace;
    %if &syscc < &cleanup_cc %then %let syscc=&cleanup_cc;
  %end;
  %if &RBC_PREPARE_OK ne 1 and %upcase(%superq(on_error)) ne RETURN %then %abort cancel;
%mend;

%macro rbc_capture_loess_prewindow(run_id=,input_snapshot_id=,code_hash=,config_hash=);
 %global RBC_PREWINDOW_OK RBC_PREWINDOW_ERROR;
 %local i idname needed n bad;
 %let RBC_PREWINDOW_OK=0;%let RBC_PREWINDOW_ERROR=NONE;
 %if %length(%superq(run_id))=0 or %length(%superq(run_id))>64 %then %do;
   %let RBC_PREWINDOW_ERROR=RUN_IDENTITY_REQUIRED;%return;
 %end;
 %if %sysfunc(prxmatch(/^[A-Za-z0-9_-]+$/,%superq(run_id))) ne 1 %then %do;
   %let RBC_PREWINDOW_ERROR=RUN_IDENTITY_REQUIRED;%return;
 %end;
 %do i=1 %to 3;
   %let idname=%scan(input_snapshot_id code_hash config_hash,&i);
   %if %length(%superq(&idname)) ne 64 %then %do;
     %let RBC_PREWINDOW_ERROR=PREPARATION_BINDING_REQUIRED;%return;
   %end;
   %if %sysfunc(prxmatch(/^[A-Fa-f0-9]{64}$/,%superq(&idname))) ne 1 %then %do;
     %let RBC_PREWINDOW_ERROR=PREPARATION_BINDING_REQUIRED;%return;
   %end;
 %end;
 %let needed=_rps_index _rps_irbad _rps_events;
 %do i=1 %to %sysfunc(countw(&needed));
   %if not %sysfunc(exist(work.%scan(&needed,&i),DATA)) %then %do;
     %let RBC_PREWINDOW_ERROR=NATIVE_STAGE_MISSING;%return;
   %end;
 %end;
 %if %sysfunc(exist(work._rps_lpsrc,DATA)) or %sysfunc(exist(work._rps_lpsrc,VIEW)) or
     %sysfunc(exist(work._rps_loess_prewindow,DATA)) or %sysfunc(exist(work._rps_loess_prewindow,VIEW)) %then %do;
   %let RBC_PREWINDOW_ERROR=FRESH_STAGE_REQUIRED;%return;
 %end;

 proc sql noprint;
 select count(*) into :bad trimmed from
 (select PersonKey,TransDt from work._rps_events group by PersonKey,TransDt having count(*) ne 1) as dup;
 select count(*) into :n trimmed from work._rps_events
 where cmiss(PersonKey,ClinicalPatientID,TransDt,AdmissionTime,DischargeTime,RBC_EventKey,ICUAdmissionKey)>0
 or AdmissionTime>TransDt or TransDt>DischargeTime;
 quit;
 %if &syscc>4 or &syserr>4 %then %do;%let RBC_PREWINDOW_ERROR=EVENT_SCOPE_QUERY_FAILED;%return;%end;
 %if &bad ne 0 or &n ne 0 %then %do;%let RBC_PREWINDOW_ERROR=EVENT_SCOPE_INVALID;%return;%end;
 data work._rps_lpsrc;
   length SourceWindowStatus $24;
   set work._rps_index(in=inside keep=PersonKey ClinicalPatientID TransDt Datetime VitalCode Value StoredAdmissionTime StoredDischargeTime)
       work._rps_irbad(in=outside where=(ReasonCode='OUTSIDE_ANALYSIS_WINDOW')
         keep=PersonKey ClinicalPatientID TransDt Datetime VitalCode Value StoredAdmissionTime StoredDischargeTime ReasonCode);
   if inside then SourceWindowStatus='IN_ANALYSIS_WINDOW';
   else SourceWindowStatus='WINDOW_ONLY_EXCLUDED';
 run;
 %if &syscc>4 or &syserr>4 %then %do;%let RBC_PREWINDOW_ERROR=SOURCE_STAGE_FAILED;%return;%end;
 proc sql;
   create table work._rps_loess_prewindow as
   select i.PersonKey,i.ClinicalPatientID,e.RBC_EventKey,e.ICUAdmissionKey,
     i.TransDt,i.Datetime,(i.Datetime-i.TransDt)/60 as TimeFromTransfusion,
     i.VitalCode,i.Value,e.AdmissionTime,e.DischargeTime,i.SourceWindowStatus
   from work._rps_lpsrc i inner join work._rps_events e
     on i.PersonKey=e.PersonKey and i.TransDt=e.TransDt
     and i.ClinicalPatientID=e.ClinicalPatientID
     and not missing(i.StoredAdmissionTime) and not missing(i.StoredDischargeTime)
     and i.StoredAdmissionTime=e.AdmissionTime and i.StoredDischargeTime=e.DischargeTime;
 quit;
 %if &syscc>4 or &syserr>4 %then %do;%let RBC_PREWINDOW_ERROR=PRIMARY_SCOPE_JOIN_FAILED;%return;%end;
 data work._rps_loess_prewindow;
   length RunId InputSnapshotId CodeHash ConfigHash $64 PrewindowProtocol $40;
   set work._rps_loess_prewindow;
   RunId="&run_id";InputSnapshotId="&input_snapshot_id";CodeHash="&code_hash";ConfigHash="&config_hash";
   PrewindowProtocol='PRIMARY_SOURCE_MULTIPLICITY_PREWINDOW_V1';
 run;
 %if &syscc>4 or &syserr>4 %then %do;%let RBC_PREWINDOW_ERROR=PREWINDOW_METADATA_FAILED;%return;%end;
 %let RBC_PREWINDOW_OK=1;
%mend;

%macro fd_fail(code);
 %let RBC_FLOW_OK=0;%let RBC_FLOW_ERROR=&code;
 %put NOTE: RBC_FLOW_CAPTURE_REJECTED &code;
%mend;
%macro fd_step;%if &syserr>4 or &syscc>4 %then %do;%fd_fail(SAS_STEP_FAILED);%return;%end;%mend;
%macro fd_metric(id=,stage=,unit=,value=,overlap=NOT_ADDITIVE,denominator=);
 data work._fd_one;
 length MetricID $96 Stage $24 CountingUnit $32 Overlap $32 DenominatorID $96;
 MetricID="&id";Stage="&stage";CountingUnit="&unit";Overlap="&overlap";
 DenominatorID="&denominator";Count=&value;output;
 run;
 proc append base=&FD_OUT..&FD_METRICS data=work._fd_one;run;%fd_step;
 %if &RBC_FLOW_ERROR ne NONE %then %return;
%mend;
%macro fd_counts(ds=,stage=,subset=,where=1,overlap=NOT_ADDITIVE);
 %local nr np ne mp mt;
 proc sql noprint;
 select coalesce(sum(NRows),0),count(distinct PersonKey),
 coalesce(sum(NRows*missing(PersonKey)),0),coalesce(sum(NRows*(cmiss(PersonKey,TransDt)>0)),0)
 into :nr trimmed,:np trimmed,:mp trimmed,:mt trimmed from &ds where &where;
 select count(*) into :ne trimmed from
 (select distinct PersonKey,TransDt from &ds where (&where) and cmiss(PersonKey,TransDt)=0) as known_events;
 quit;%fd_step;
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %fd_metric(id=&stage._&subset._ROWS,stage=&stage,unit=&FD_ROW_UNIT,value=&nr,overlap=&overlap,denominator=&stage._ALL_ROWS);
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %fd_metric(id=&stage._&subset._PERSONS,stage=&stage,unit=KNOWN_PERSONS,value=&np,denominator=&stage._ALL_PERSONS);
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %fd_metric(id=&stage._&subset._EVENTS,stage=&stage,unit=KNOWN_EVENT_KEYS,value=&ne,denominator=&stage._ALL_EVENTS);
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %fd_metric(id=&stage._&subset._NO_PERSON_ROWS,stage=&stage,unit=&FD_ROW_UNIT,value=&mp,denominator=&stage._&subset._ROWS);
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %fd_metric(id=&stage._&subset._NO_EVENT_ROWS,stage=&stage,unit=&FD_ROW_UNIT,value=&mt,denominator=&stage._&subset._ROWS);
 %if &RBC_FLOW_ERROR ne NONE %then %return;
%mend;
%macro fd_stage(ds=,stage=,reasons=);
 %local k reason unit table n affected lost partial retained;
 %fd_counts(ds=&ds,stage=&stage,subset=ALL);
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %fd_counts(ds=&ds,stage=&stage,subset=PASS,where=IsPass=1,overlap=DISJOINT_PASS_FAIL_ROWS);
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %fd_counts(ds=&ds,stage=&stage,subset=FAIL,where=IsPass=0,overlap=DISJOINT_PASS_FAIL_ROWS);
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %do k=1 %to %sysfunc(countw(&reasons,%str( )));
 %let reason=%scan(&reasons,&k,%str( ));
 %fd_counts(ds=&ds,stage=&stage,subset=&reason,where=ReasonCode="&reason",overlap=FIRST_FAILURE_ROWS_ONLY);
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %end;
 proc sql;
 create table work._fd_loss_person as select PersonKey,sum(NRows) as TotalRows,
 sum(NRows*IsPass) as PassRows from &ds where not missing(PersonKey) group by PersonKey;
 create table work._fd_loss_event as select PersonKey,TransDt,sum(NRows) as TotalRows,
 sum(NRows*IsPass) as PassRows from &ds where cmiss(PersonKey,TransDt)=0 group by PersonKey,TransDt;
 quit;%fd_step;
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %do k=1 %to 2;
 %let table=%scan(person event,&k);%let unit=%scan(KNOWN_PERSONS KNOWN_EVENT_KEYS,&k);
 proc sql noprint;select count(*),coalesce(sum(PassRows<TotalRows),0),coalesce(sum(PassRows=0),0),
 coalesce(sum(PassRows>0 and PassRows<TotalRows),0),coalesce(sum(PassRows=TotalRows),0)
 into :n trimmed,:affected trimmed,:lost trimmed,:partial trimmed,:retained trimmed from work._fd_loss_&table;
 quit;%fd_step;
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %if %sysevalf(&n ne &lost+&partial+&retained) or %sysevalf(&affected ne &lost+&partial) %then %do;%fd_fail(ENTITY_PARTITION_FAILED);%return;%end;
 %fd_metric(id=&stage._FULLY_LOST_&unit,stage=&stage,unit=&unit,value=&lost,overlap=DISJOINT_ENTITY_PARTITION,denominator=&stage._ALL_%scan(PERSONS EVENTS,&k));
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %fd_metric(id=&stage._PARTLY_RETAINED_&unit,stage=&stage,unit=&unit,value=&partial,overlap=DISJOINT_ENTITY_PARTITION,denominator=&stage._ALL_%scan(PERSONS EVENTS,&k));
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %fd_metric(id=&stage._UNTOUCHED_&unit,stage=&stage,unit=&unit,value=&retained,overlap=DISJOINT_ENTITY_PARTITION,denominator=&stage._ALL_%scan(PERSONS EVENTS,&k));
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %fd_metric(id=&stage._ANY_AFFECTED_&unit,stage=&stage,unit=&unit,value=&affected,overlap=LOST_PLUS_PARTLY_RETAINED,denominator=&stage._ALL_%scan(PERSONS EVENTS,&k));
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %end;
%mend;

%macro rbc_capture_reason_flow(good=,bad=,group=,reason_list=,stage_list=,row_unit=);
 %local j reason stage;
 %let FD_ROW_UNIT=&row_unit;
 data work._fd_remaining;
   length ReasonCode $48;
   set &good(in=accepted keep=PersonKey TransDt)
       &bad(keep=PersonKey TransDt ReasonCode);
   if accepted then ReasonCode='';NRows=1;
 run;%fd_step;
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %do j=1 %to %sysfunc(countw(&reason_list));
   %let reason=%scan(&reason_list,&j);%let stage=%scan(&stage_list,&j);
   data work._fd_remaining;set work._fd_remaining;IsPass=(ReasonCode ne "&reason");run;%fd_step;
 %if &RBC_FLOW_ERROR ne NONE %then %return;
   %fd_stage(ds=work._fd_remaining,stage=&stage,reasons=&reason);
 %if &RBC_FLOW_ERROR ne NONE %then %return;
   data work._fd_remaining;set work._fd_remaining;if IsPass=1;run;%fd_step;
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %end;
 proc sql noprint;select count(*) into :FD_UNCLASSIFIED trimmed from work._fd_remaining where not missing(ReasonCode);quit;%fd_step;
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %if &FD_UNCLASSIFIED ne 0 %then %do;%fd_fail(UNKNOWN_NATIVE_REASON);%return;%end;
%mend;
%macro rbc_capture_preparation_flow(outlib=WORK,metrics=_rps_flow_metrics,checks=_rps_flow_checks,
 run_id=,input_snapshot_id=,code_hash=,config_hash=);
 %global FD_OUT FD_METRICS FD_ROW_UNIT FD_UNCLASSIFIED RBC_FLOW_OK RBC_FLOW_ERROR;
 %local n needed i mclinic mtime idname;
 %let RBC_FLOW_OK=0;%let RBC_FLOW_ERROR=NONE;
 %let FD_OUT=&outlib;%let FD_METRICS=&metrics;
 %if %upcase(%superq(outlib)) ne WORK %then %do;%fd_fail(WORK_STAGE_REQUIRED);%return;%end;
 %if %superq(metrics) ne _rps_flow_metrics or %superq(checks) ne _rps_flow_checks %then %do;%fd_fail(OWNED_STAGE_NAMES_REQUIRED);%return;%end;
 %if %length(%superq(run_id))=0 or %length(%superq(run_id))>64 or
 %sysfunc(prxmatch(/^[A-Za-z0-9_-]+$/,%superq(run_id))) ne 1 %then %do;%fd_fail(RUN_IDENTITY_REQUIRED);%return;%end;
 %do i=1 %to 3;
 %let idname=%scan(input_snapshot_id code_hash config_hash,&i);
 %if %length(%superq(&idname)) ne 64 %then %do;%fd_fail(PREPARATION_BINDING_REQUIRED);%return;%end;
 %if %sysfunc(prxmatch(/^[A-Fa-f0-9]{64}$/,%superq(&idname))) ne 1 %then %do;%fd_fail(PREPARATION_BINDING_REQUIRED);%return;%end;
 %end;
 %if not %sysfunc(nvalid(&outlib,V7)) or %length(&outlib)>8 or %sysfunc(libref(&outlib)) ne 0 %then %do;%fd_fail(OUTPUT_LIBREF_INVALID);%return;%end;
 %if %sysfunc(exist(&outlib..&metrics)) or %sysfunc(exist(&outlib..&checks)) %then %do;%fd_fail(FRESH_OUTPUT_REQUIRED);%return;%end;
 %let needed=_rps_index _rps_irbad _rps_linkgood _rps_linkbad _rps_eaccept _rps_ebad _rps_long;
 %do i=1 %to %sysfunc(countw(&needed));
   %if not %sysfunc(exist(work.%scan(&needed,&i),DATA)) %then %do;%fd_fail(NATIVE_STAGE_MISSING);%return;%end;
 %end;
 proc sql noprint;select count(*) into :n trimmed from dictionary.tables where libname='WORK' and substr(upcase(memname),1,4)='_FD_';quit;%fd_step;
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %if &n ne 0 %then %do;%fd_fail(SCRATCH_COLLISION);%return;%end;
 data &outlib..&metrics;length MetricID $96 Stage $24 CountingUnit $32 Overlap $32 DenominatorID $96 Count 8;stop;run;
 data work._fd_identity;
 set work._rps_index(keep=ClinicalPatientID TransDt) work._rps_irbad(keep=ClinicalPatientID TransDt);
 run;%fd_step;
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 proc sql noprint;
 select coalesce(sum(missing(ClinicalPatientID)),0),coalesce(sum(missing(TransDt)),0)
 into :mclinic trimmed,:mtime trimmed from work._fd_identity;
 quit;%fd_step;
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %fd_metric(id=SOURCE_MISSING_CLINICAL_ID_ROWS,stage=SOURCE_IDENTITY,unit=INDEX_EXTRACT_ROWS,value=&mclinic,denominator=SOURCE_IDENTITY_ALL_ROWS);
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %fd_metric(id=SOURCE_MISSING_EVENT_TIME_ROWS,stage=SOURCE_IDENTITY,unit=INDEX_EXTRACT_ROWS,value=&mtime,denominator=SOURCE_IDENTITY_ALL_ROWS);
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %rbc_capture_reason_flow(good=work._rps_index,bad=work._rps_irbad,group=SOURCE,row_unit=INDEX_EXTRACT_ROWS,
  reason_list=MISSING_SOURCE_EVENT_KEY OUTSIDE_DECLARED_OUTCOMES MISSING_MEASUREMENT_TIME OUTSIDE_ANALYSIS_WINDOW,
  stage_list=SOURCE_IDENTITY SOURCE_OUTCOME SOURCE_MEASUREMENT_TIME SOURCE_WINDOW);
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %rbc_capture_reason_flow(good=work._rps_linkgood,bad=work._rps_linkbad,group=ADMISSION,row_unit=INDEX_EXTRACT_ROWS,
  reason_list=INVALID_ADMISSION_HISTORY NO_ADMISSION_CONTAINS_INDEX MULTIPLE_ADMISSIONS_CONTAIN_INDEX STORED_CLINICAL_ID_MISMATCH STORED_ADMISSION_BOUNDS_MISMATCH,
  stage_list=ADMISSION_VALID_HISTORY ADMISSION_CONTAINS_INDEX ADMISSION_UNIQUE_MATCH ADMISSION_STORED_ID ADMISSION_STORED_BOUNDS);
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %rbc_capture_reason_flow(good=work._rps_eaccept,bad=work._rps_ebad,group=HISTORY,row_unit=CANONICAL_EVENT_ROWS,
  reason_list=INDEX_EVENT_ABSENT_FROM_LEDGER AMBIGUOUS_PRIOR_UNIT_ADMISSION PREVIOUS_RBC_WITHIN_OR_AT_MINUS12H,
  stage_list=HISTORY_INDEX_PRESENT HISTORY_PRIOR_CLEAR HISTORY_12H);
 %if &RBC_FLOW_ERROR ne NONE %then %return;
  
 %let FD_ROW_UNIT=CANONICAL_ANALYSIS_ROWS;
 data work._fd_remaining;set work._rps_long(keep=PersonKey TransDt);NRows=1;run;%fd_step;
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %fd_counts(ds=work._fd_remaining,stage=CANONICAL_RECONCILED,subset=ALL);
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 proc sql noprint;select count(*) into :n trimmed from &outlib..&metrics where missing(Count) or Count<0 or Count ne floor(Count);quit;%fd_step;
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %if &n ne 0 %then %do;%fd_fail(AGGREGATE_COUNT_INVALID);%return;%end;
 data &outlib..&metrics;
 length RunId InputSnapshotId CodeHash ConfigHash $64 FlowProtocol $40;
 set &outlib..&metrics;
 RunId="&run_id";InputSnapshotId="&input_snapshot_id";CodeHash="&code_hash";ConfigHash="&config_hash";
 FlowProtocol='NATIVE_PREPARATION_REASON_FLOW_V1';
 keep RunId InputSnapshotId CodeHash ConfigHash FlowProtocol MetricID Stage CountingUnit Overlap DenominatorID Count;
 run;
 data &outlib..&checks;
 length RunId InputSnapshotId CodeHash ConfigHash $64 FlowProtocol $40 Check $64 Status $16;
 RunId="&run_id";InputSnapshotId="&input_snapshot_id";CodeHash="&code_hash";ConfigHash="&config_hash";
 FlowProtocol='NATIVE_PREPARATION_REASON_FLOW_V1';
 Check='NATIVE_FIRST_FAILURE_REASONS_COVERED';Status='PASS';output;
 Check='KNOWN_ENTITY_PARTITIONS_EXACT';Status='PASS';output;
 Check='AGGREGATE_COUNTS_NONNEGATIVE_INTEGERS';Status='PASS';output;
 run;%fd_step;
 %if &RBC_FLOW_ERROR ne NONE %then %return;
 %let RBC_FLOW_OK=1;
  
%mend;

%macro rbc_population_fail(reason);
  %let RBC_POPULATIONS_OK=0;
  %let RBC_POPULATIONS_REASON=&reason;
%mend;

%macro rbc_make_populations(events=,units=,coverage=,outlib=,
  run_id=,analysis_spec_id=,cohort_mode=,mapping_verified=NO,
  primary_eligibility_verified=NO,coverage_verified=NO,
  end_boundary=INCLUSIVE,coverage_scope=UNSPECIFIED,on_error=ABORT);
  %global RBC_POPULATIONS_OK RBC_POPULATIONS_REASON;
  %local outs scratch i j ds vars types var h pos rc bad n allocated created inputlib inputmem;
  %let RBC_POPULATIONS_OK=0;
  %let RBC_POPULATIONS_REASON=NOT_STARTED;
  %let allocated=0; %let created=0;
  %let outs=population_flags population_members population_counts followup_counts;
  %let scratch=_rpop_min _rpop_future _rpop_csort _rpop_merged _rpop_cover _rpop_seed;
  %if %upcase(%superq(on_error)) ne ABORT and %upcase(%superq(on_error)) ne RETURN %then %do;
    %let on_error=ABORT;
    %rbc_population_fail(ERROR_POLICY_INVALID); %goto finish;
  %end;
  %let end_boundary=%upcase(%superq(end_boundary));
  %let coverage_scope=%upcase(%superq(coverage_scope));
  %if &end_boundary ne INCLUSIVE and &end_boundary ne EXCLUSIVE %then %do;
    %rbc_population_fail(COVERAGE_END_BOUNDARY_INVALID); %goto finish;
  %end;
  %if &coverage_scope ne UNSPECIFIED and
      &coverage_scope ne RECORDED_RBC_EXTRACTION_1973_2018 %then %do;
    %rbc_population_fail(COVERAGE_SCOPE_INVALID); %goto finish;
  %end;
  %if &coverage_scope=RECORDED_RBC_EXTRACTION_1973_2018 and &end_boundary ne EXCLUSIVE %then %do;
    %rbc_population_fail(RECORDED_EXTRACTION_REQUIRES_EXCLUSIVE_END); %goto finish;
  %end;
  %if &syscc>4 or &syserr>4 %then %do;
    %rbc_population_fail(SAS_SESSION_NOT_CLEAN); %goto finish;
  %end;
  %if %upcase(%superq(mapping_verified)) ne YES or
      %upcase(%superq(primary_eligibility_verified)) ne YES or
      %upcase(%superq(coverage_verified)) ne YES %then %do;
    %rbc_population_fail(VERIFIED_MAPPING_ELIGIBILITY_COVERAGE_REQUIRED);
    %goto finish;
  %end;
  %if %length(%superq(run_id))=0 or %length(%superq(run_id))>64 or
      %length(%superq(analysis_spec_id))=0 or %length(%superq(analysis_spec_id))>80 or
      (%upcase(%superq(cohort_mode)) ne DEVELOPMENT_SAMPLE and
       %upcase(%superq(cohort_mode)) ne FULL_COHORT) %then %do;
    %rbc_population_fail(RUN_IDENTITY_REQUIRED); %goto finish;
  %end;
  %if %length(%superq(outlib))=0 %then %do;
    %rbc_population_fail(OUTPUT_LIBRARY_REQUIRED); %goto finish;
  %end;
  %if %sysfunc(nvalid(%superq(outlib),V7))=0 or %length(%superq(outlib))>8 %then %do;
    %rbc_population_fail(OUTPUT_LIBRARY_INVALID); %goto finish;
  %end;
  %if %sysfunc(libref(&outlib)) ne 0 %then %do;
    %rbc_population_fail(OUTPUT_LIBRARY_UNASSIGNED); %goto finish;
  %end;
  %do i=1 %to %sysfunc(countw(&outs));
    %let ds=&outlib..%scan(&outs,&i);
    %if %sysfunc(exist(&ds,DATA)) or %sysfunc(exist(&ds,VIEW)) %then %do;
      %rbc_population_fail(OUTPUT_ALREADY_EXISTS); %goto finish;
    %end;
  %end;
  %do i=1 %to %sysfunc(countw(&scratch));
    %let ds=work.%scan(&scratch,&i);
    %if %sysfunc(exist(&ds,DATA)) or %sysfunc(exist(&ds,VIEW)) %then %do;
      %rbc_population_fail(SCRATCH_ALREADY_EXISTS); %goto finish;
    %end;
  %end;
  %do i=1 %to 3;
    %if &i=1 %then %do;
      %let ds=&events; %let vars=PersonKey TransDt RBC_EventKey;
      %let types=N N C;
    %end;
    %else %if &i=2 %then %do;
      %let ds=&units; %let vars=PersonKey TransDt RBC_UnitKey;
      %let types=N N C;
    %end;
    %else %do;
      %let ds=&coverage; %let vars=PersonKey CoverageStart CoverageEnd;
      %let types=N N N;
    %end;
    %if %length(%superq(ds))=0 %then %do;
      %rbc_population_fail(INPUT_REQUIRED); %goto finish;
    %end;
    %if %sysfunc(countc(%superq(ds),%str(.))) ne 1 %then %do;
      %rbc_population_fail(TWO_LEVEL_DATA_NAME_REQUIRED); %goto finish;
    %end;
    %let inputlib=%qscan(%superq(ds),1,%str(.));
    %let inputmem=%qscan(%superq(ds),2,%str(.));
    %if %length(%superq(inputlib))=0 or %length(%superq(inputlib))>8 or
        %length(%superq(inputmem))=0 or %length(%superq(inputmem))>32 %then %do;
      %rbc_population_fail(INPUT_DATA_NAME_INVALID); %goto finish;
    %end;
    %if %sysfunc(nvalid(%superq(inputlib),V7))=0 or
        %sysfunc(nvalid(%superq(inputmem),V7))=0 %then %do;
      %rbc_population_fail(INPUT_DATA_NAME_INVALID); %goto finish;
    %end;
    %if not %sysfunc(exist(&ds,DATA)) %then %do;
      %rbc_population_fail(INPUT_TABLE_REQUIRED); %goto finish;
    %end;
    %let h=%sysfunc(open(&ds,i));
    %if &h=0 %then %do;
      %rbc_population_fail(INPUT_METADATA_UNAVAILABLE); %goto finish;
    %end;
    %do j=1 %to 3;
      %let var=%scan(&vars,&j);
      %let pos=%sysfunc(varnum(&h,&var));
      %if &pos=0 %then %do;
        %let rc=%sysfunc(close(&h));
        %rbc_population_fail(INPUT_COLUMN_REQUIRED); %goto finish;
      %end;
      %if %sysfunc(vartype(&h,&pos)) ne %scan(&types,&j) %then %do;
        %let rc=%sysfunc(close(&h));
        %rbc_population_fail(INPUT_COLUMN_TYPE); %goto finish;
      %end;
    %end;
    %let rc=%sysfunc(close(&h));
  %end;
  %let allocated=1;
  proc sql noprint;
    select count(*) into :n trimmed from &events;
    select count(*) into :bad trimmed from &events
      where cmiss(PersonKey,TransDt,RBC_EventKey)>0;
  quit;
  %if &syscc>4 or &syserr>4 %then %goto sas_failure;
  %if &n=0 or &bad>0 %then %do;
    %rbc_population_fail(INVALID_EVENT_KEYS); %goto finish;
  %end;
  proc sql noprint;
    select count(*) into :bad trimmed from
      (select RBC_EventKey from &events group by RBC_EventKey having count(*) ne 1);
  quit;
  %if &syscc>4 or &syserr>4 %then %goto sas_failure;
  %if &bad>0 %then %do;
    %rbc_population_fail(DUPLICATE_EVENT_KEY); %goto finish;
  %end;
  proc sql noprint;
    select count(*) into :bad trimmed from
      (select PersonKey,TransDt from &events group by PersonKey,TransDt having count(*) ne 1);
  quit;
  %if &syscc>4 or &syserr>4 %then %goto sas_failure;
  %if &bad>0 %then %do;
    %rbc_population_fail(CONCURRENT_EVENTS_REQUIRE_CANONICALIZATION); %goto finish;
  %end;
  proc sql noprint;
    select count(*) into :bad trimmed from &units
      where cmiss(PersonKey,TransDt,RBC_UnitKey)>0;
  quit;
  %if &syscc>4 or &syserr>4 %then %goto sas_failure;
  %if &bad>0 %then %do;
    %rbc_population_fail(INVALID_UNIT_KEYS); %goto finish;
  %end;
  proc sql noprint;
    select count(*) into :bad trimmed from
      (select RBC_UnitKey from &units group by RBC_UnitKey having count(*) ne 1);
  quit;
  %if &syscc>4 or &syserr>4 %then %goto sas_failure;
  %if &bad>0 %then %do;
    %rbc_population_fail(DUPLICATE_PHYSICAL_UNIT); %goto finish;
  %end;
  proc sql noprint;
    select count(*) into :bad trimmed from &events e where not exists
      (select * from &units u where e.PersonKey=u.PersonKey and e.TransDt=u.TransDt);
  quit;
  %if &syscc>4 or &syserr>4 %then %goto sas_failure;
  %if &bad>0 %then %do;
    %rbc_population_fail(INDEX_EVENT_ABSENT_FROM_LEDGER); %goto finish;
  %end;
  proc sql noprint;
    select count(*) into :bad trimmed from &coverage
      where cmiss(PersonKey,CoverageStart,CoverageEnd)>0 or CoverageEnd<CoverageStart
        %if &end_boundary=EXCLUSIVE %then %do; or CoverageEnd=CoverageStart %end;
        %if &coverage_scope=RECORDED_RBC_EXTRACTION_1973_2018 %then %do;
          or CoverageStart ne '01JAN1973:00:00:00'dt or CoverageEnd ne '01JAN2019:00:00:00'dt
        %end;
      ;
  quit;
  %if &syscc>4 or &syserr>4 %then %goto sas_failure;
  %if &bad>0 %then %do;
    %rbc_population_fail(INVALID_COVERAGE_INTERVAL); %goto finish;
  %end;
  proc sort data=&coverage(keep=PersonKey CoverageStart CoverageEnd)
    out=work._rpop_csort;
    by PersonKey CoverageStart CoverageEnd;
  run;
  %if &syscc>4 or &syserr>4 %then %goto sas_failure;
  data work._rpop_merged(keep=PersonKey VerifiedStart VerifiedEnd);
    set work._rpop_csort;
    by PersonKey;
    retain VerifiedStart VerifiedEnd;
    if first.PersonKey then do;
      VerifiedStart=CoverageStart; VerifiedEnd=CoverageEnd;
    end;
    else if CoverageStart<=VerifiedEnd then VerifiedEnd=max(VerifiedEnd,CoverageEnd);
    else do;
      output; VerifiedStart=CoverageStart; VerifiedEnd=CoverageEnd;
    end;
    if last.PersonKey then output;
  run;
  %if &syscc>4 or &syserr>4 %then %goto sas_failure;
  proc sql noprint;
    create table work._rpop_min as
      select PersonKey,min(TransDt) as FirstTime from &events group by PersonKey;
    create table work._rpop_future as
      select e.RBC_EventKey,count(u.RBC_UnitKey) as NFollowingUnits
      from &events e left join &units u on e.PersonKey=u.PersonKey and
        u.TransDt>e.TransDt and u.TransDt<=e.TransDt+43200
      group by e.RBC_EventKey;
    create table work._rpop_cover as
      select e.RBC_EventKey,count(c.PersonKey) as CoverageMatches
      from &events e left join work._rpop_merged c on e.PersonKey=c.PersonKey and
        c.VerifiedStart<=e.TransDt and c.VerifiedEnd
          %if &end_boundary=EXCLUSIVE %then %do; > %end;
          %else %do; >= %end;
          e.TransDt+43200
      group by e.RBC_EventKey;
  quit;
  %if &syscc>4 or &syserr>4 %then %goto sas_failure;
  %let created=1;
  proc sql noprint;
    create table &outlib..population_flags as
      select e.PersonKey,e.TransDt,e.RBC_EventKey,
        (e.TransDt=m.FirstTime) as FirstEligibleEvent,
        f.NFollowingUnits,(c.CoverageMatches=1) as FutureCoverageComplete,
        (f.NFollowingUnits=0 and c.CoverageMatches=1) as NoFollowingUnit12H
      from &events e inner join work._rpop_min m on e.PersonKey=m.PersonKey
      inner join work._rpop_future f on e.RBC_EventKey=f.RBC_EventKey
      inner join work._rpop_cover c on e.RBC_EventKey=c.RBC_EventKey;
  quit;
  %if &syscc>4 or &syserr>4 %then %goto sas_failure;
  data &outlib..population_flags;
    length FollowupStatus $32 RunId $64 AnalysisSpecId $80 CohortMode $24 ExportStatus $24
      CoverageScope $48 CoverageEndBoundary $12 FollowupDefinition $64;
    set &outlib..population_flags;
    if NFollowingUnits>0 then FollowupStatus='FOLLOWING_UNIT';
    else if FutureCoverageComplete then FollowupStatus='VERIFIED_NO_FOLLOWING_UNIT';
    else FollowupStatus='UNKNOWN_FOLLOWUP';
    CoverageScope=symget('coverage_scope'); CoverageEndBoundary=symget('end_boundary');
    FollowupDefinition='NO_FOLLOWING_RBC_IN_0_TO_12H';
    if CoverageScope='RECORDED_RBC_EXTRACTION_1973_2018' then do;
      FollowupDefinition='NO_FOLLOWING_RECORDED_RBC_IN_0_TO_12H';
      if NFollowingUnits>0 then FollowupStatus='FOLLOWING_RECORDED_UNIT';
      else if FutureCoverageComplete then FollowupStatus='NO_FOLLOWING_RECORDED_UNIT';
    end;
    RunId=symget('run_id'); AnalysisSpecId=symget('analysis_spec_id');
    CohortMode=lowcase(symget('cohort_mode')); ExportStatus='PRIVATE_UNREVIEWED';
  run;
  data &outlib..population_members;
    length PopulationId $32;
    set &outlib..population_flags;
    PopulationId='PRIMARY'; output;
    if FirstEligibleEvent then do; PopulationId='FIRST_EVENT'; output; end;
    if NoFollowingUnit12H then do; PopulationId='NO_FOLLOWING_UNIT_12H'; output; end;
  run;
  data work._rpop_seed;
    length PopulationId $32;
    PopulationId='PRIMARY'; output;
    PopulationId='FIRST_EVENT'; output;
    PopulationId='NO_FOLLOWING_UNIT_12H'; output;
  run;
  %if &syscc>4 or &syserr>4 %then %goto sas_failure;
  proc sql noprint;
    create table &outlib..population_counts as
      select s.PopulationId,'AVAILABLE' as PopulationStatus length=40,
        count(m.RBC_EventKey) as NEvents,
        count(distinct m.PersonKey) as NPersons
      from work._rpop_seed s left join &outlib..population_members m
        on s.PopulationId=m.PopulationId group by s.PopulationId;
    create table &outlib..followup_counts as
      select FollowupStatus,count(*) as NEvents,count(distinct PersonKey) as NPersons
      from &outlib..population_flags group by FollowupStatus;
  quit;
  %if &syscc>4 or &syserr>4 %then %goto sas_failure;
  %do i=1 %to 2;
    %if &i=1 %then %let ds=&outlib..population_counts;
    %else %let ds=&outlib..followup_counts;
    data &ds;
      length RunId $64 AnalysisSpecId $80 CohortMode $24 ExportStatus $24
        CoverageScope $48 CoverageEndBoundary $12 FollowupDefinition $64;
      set &ds;
      CoverageScope=symget('coverage_scope'); CoverageEndBoundary=symget('end_boundary');
      FollowupDefinition='NO_FOLLOWING_RBC_IN_0_TO_12H';
      if CoverageScope='RECORDED_RBC_EXTRACTION_1973_2018' then
        FollowupDefinition='NO_FOLLOWING_RECORDED_RBC_IN_0_TO_12H';
      RunId=symget('run_id'); AnalysisSpecId=symget('analysis_spec_id');
      CohortMode=lowcase(symget('cohort_mode')); ExportStatus='PRIVATE_UNREVIEWED';
    run;
    %if &syscc>4 or &syserr>4 %then %goto sas_failure;
  %end;
  %let RBC_POPULATIONS_OK=1;
  %let RBC_POPULATIONS_REASON=CANONICAL_POPULATIONS_BUILT;
  %goto finish;
%sas_failure:
  %rbc_population_fail(SAS_STEP_FAILED);
%finish:
  %if &allocated %then %do;
    proc datasets library=work nolist nowarn; delete &scratch; quit;
    %if &syscc>4 or &syserr>4 %then %rbc_population_fail(SAS_CLEANUP_FAILED);
  %end;
  %if &created and &RBC_POPULATIONS_OK=0 %then %do;
    proc datasets library=&outlib nolist nowarn; delete &outs; quit;
    %do i=1 %to %sysfunc(countw(&outs));
      %if %sysfunc(exist(&outlib..%scan(&outs,&i))) %then
        %rbc_population_fail(FAILED_OUTPUT_REMAINS);
    %end;
  %end;
  %if &RBC_POPULATIONS_OK=0 %then %do;
    %if %upcase(%superq(on_error))=ABORT %then %do;
      %put ERROR: RBC_POPULATIONS_FAILED &RBC_POPULATIONS_REASON;
      %abort cancel;
    %end;
    %else %put NOTE: RBC_POPULATIONS_EXPECTED_OR_HANDLED_FAILURE &RBC_POPULATIONS_REASON;
  %end;
%mend;

