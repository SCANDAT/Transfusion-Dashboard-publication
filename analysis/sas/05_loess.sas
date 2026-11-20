/* Descriptive LOESS.
   Measurement grouping/thinning, quadratic direct LOESS, recorded and standardized scales, interpolation to the display grid and support gaps.
   This file defines macros; use run.py to execute the analysis steps.
*/
%macro rbc_loess_direct_display_grid(points=,scaling=,units=,out=,
 report_id=SYNTHETIC_LOESS,grid_min=-720,grid_max=720,grid_step=1,
 span_min=10,span_max=90);
 %local tag a b c d e f g h j n bad i z span_count grid_count;
 %global RBC_LOESS_GRID_OK RBC_LOESS_GRID_REASON;
 %let RBC_LOESS_GRID_OK=0; %let RBC_LOESS_GRID_REASON=NOT_COMPLETED;
 %if &syscc ne 0 or &syserr ne 0 %then %do; %let RBC_LOESS_GRID_REASON=PRIOR_SAS_FAILURE; %goto finish; %end;
 %if %length(%superq(out))=0 or %length(%superq(points))=0 or %length(%superq(scaling))=0 or %length(%superq(units))=0 %then %do;
  %let RBC_LOESS_GRID_REASON=DATA_ARGUMENT_REQUIRED; %goto finish;
 %end;
 %if %sysfunc(exist(&out,DATA)) or %sysfunc(exist(&out,VIEW)) %then %do;
  %let RBC_LOESS_GRID_REASON=OUTPUT_ALREADY_EXISTS; %goto finish;
 %end;
 %if %sysfunc(prxmatch(%str(/^[A-Za-z0-9_.:-]{1,64}$/),%superq(report_id))) ne 1 %then %do;
  %let RBC_LOESS_GRID_REASON=REPORT_ID_REJECTED; %goto finish;
 %end;
 %do i=1 %to 5;
  %let z=%scan(grid_min grid_max grid_step span_min span_max,&i);
  %if %sysfunc(prxmatch(%str(/^-?[0-9]+$/),%superq(&z))) ne 1 %then %do;
   %let RBC_LOESS_GRID_REASON=GRID_CONFIGURATION_REJECTED; %goto finish;
  %end;
 %end;
 %if &grid_step<1 or &grid_min>&grid_max or &grid_min< -720 or &grid_max>720 or
     &span_min<10 or &span_max>90 or &span_min>&span_max %then %do;
  %let RBC_LOESS_GRID_REASON=GRID_CONFIGURATION_REJECTED; %goto finish;
 %end;
 %if %sysfunc(mod(%eval(&grid_max-&grid_min),&grid_step)) ne 0 %then %do;
  %let RBC_LOESS_GRID_REASON=GRID_CONFIGURATION_REJECTED; %goto finish;
 %end;
 %let tag=%substr(%sysfunc(compress(%sysfunc(uuidgen()),-)),1,12);
 %let a=work._la&tag.a; %let b=work._la&tag.b; %let c=work._la&tag.c;
 %let d=work._la&tag.d; %let e=work._la&tag.e; %let f=work._la&tag.f;
 %let g=work._la&tag.g; %let h=work._la&tag.h; %let j=work._la&tag.j;
 data &a;
  length VitalCode $8;
  do _PlanIndex=1 to 7;
   VitalCode=scan('ARTm ARTs ARTd HR FIO2 SPO2 VE',_PlanIndex);
   output;
  end;
  keep VitalCode;
 run;
  
 proc sql noprint;
  select count(*) into :bad trimmed from &points p left join &a a on p.VitalCode=a.VitalCode
   where missing(a.VitalCode) or missing(p.SpanPercent) or p.SpanPercent ne int(p.SpanPercent)
    or p.SpanPercent<&span_min or p.SpanPercent>&span_max or missing(p.TimeFromTransfusion);
  select count(*) into :n trimmed from
   (select VitalCode,SpanPercent,TimeFromTransfusion,count(*) as n from &points
    where not missing(Z_Mean) group by VitalCode,SpanPercent,TimeFromTransfusion having n ne 1);
 quit;
 %if &bad ne 0 or &n ne 0 %then %do; %let RBC_LOESS_GRID_REASON=POINT_KEYS_REJECTED; %goto finish; %end;
 proc sql noprint;
  select count(*) into :bad trimmed from
   (select a.VitalCode,count(s.VitalCode) as n from &a a left join &scaling s on a.VitalCode=s.VitalCode group by a.VitalCode having n ne 1);
  select count(*) into :n trimmed from
   (select a.VitalCode,count(u.VitalCode) as n from &a a left join &units u on a.VitalCode=u.VitalCode group by a.VitalCode having n ne 1);
 quit;
 %if &bad ne 0 or &n ne 0 %then %do; %let RBC_LOESS_GRID_REASON=SCALING_OR_UNIT_KEYS_REJECTED; %goto finish; %end;
 proc sql noprint;
  select count(*) into :bad trimmed from &points p inner join &scaling s on p.VitalCode=s.VitalCode
   where not missing(p.Z_Mean) and (missing(s.GlobalMean) or missing(s.GlobalStd) or s.GlobalStd<=0);
  select count(*) into :n trimmed from &a a inner join &units u on a.VitalCode=u.VitalCode
   where missing(u.Unit) or missing(u.UnitStatus);
 quit;
 %if &bad ne 0 or &n ne 0 %then %do; %let RBC_LOESS_GRID_REASON=SCALE_OR_UNIT_BINDING_REJECTED; %goto finish; %end;
 data &b;
  set &points(keep=VitalCode SpanPercent TimeFromTransfusion Z_Mean Pred);
  if not missing(Z_Mean);
  _Kind=0; GridPointId=.;
  keep VitalCode SpanPercent TimeFromTransfusion Pred _Kind GridPointId;
 run;
 data &c;
  set &a;
  _Kind=1; Pred=.;
  do SpanPercent=&span_min to &span_max;
   do GridPointId=1 to %eval((&grid_max-&grid_min)/&grid_step+1);
    TimeFromTransfusion=&grid_min+(GridPointId-1)*&grid_step; output;
   end;
  end;
  keep VitalCode SpanPercent TimeFromTransfusion Pred _Kind GridPointId;
 run;
 data &d; set &b &c; run;
 proc sort data=&d; by VitalCode SpanPercent TimeFromTransfusion _Kind; run;
 data &e;
  set &d; by VitalCode SpanPercent TimeFromTransfusion _Kind;
  retain LeftX LeftY HasLeft;
  if first.SpanPercent then do; call missing(LeftX,LeftY); HasLeft=0; end;
  if _Kind=0 then do; LeftX=TimeFromTransfusion; LeftY=Pred; HasLeft=1; end;
  else output;
  keep VitalCode SpanPercent TimeFromTransfusion GridPointId LeftX LeftY HasLeft;
 run;
 proc sort data=&d; by VitalCode SpanPercent descending TimeFromTransfusion _Kind; run;
 data &f;
  set &d; by VitalCode SpanPercent descending TimeFromTransfusion _Kind;
  retain RightX RightY HasRight;
  if first.SpanPercent then do; call missing(RightX,RightY); HasRight=0; end;
  if _Kind=0 then do; RightX=TimeFromTransfusion; RightY=Pred; HasRight=1; end;
  else output;
  keep VitalCode SpanPercent TimeFromTransfusion GridPointId RightX RightY HasRight;
 run;
 proc sort data=&f; by VitalCode SpanPercent TimeFromTransfusion GridPointId; run;
 data &g;
  merge &e &f; by VitalCode SpanPercent TimeFromTransfusion GridPointId;
  length PointStatus $40 SupportStatus $40;
  Estimate=.;
  if HasLeft=0 and HasRight=0 then do;
   PointStatus='UNAVAILABLE_NO_RETAINED_INPUT'; SupportStatus='NO_RETAINED_INPUT';
  end;
  else if HasLeft=0 or HasRight=0 then do;
   PointStatus='OUTSIDE_RETAINED_SUPPORT'; SupportStatus='OUTSIDE_RETAINED_SUPPORT';
  end;
  else do;
   SupportStatus='WITHIN_RETAINED_RANGE';
   if missing(LeftY) or missing(RightY) then PointStatus='FIT_UNAVAILABLE';
   else if LeftX=TimeFromTransfusion and RightX=TimeFromTransfusion then do;
    if LeftY ne RightY then PointStatus='FIT_UNAVAILABLE';
    else do; Estimate=LeftY; PointStatus='AVAILABLE_EXACT_KNOT'; end;
   end;
   else if LeftX<TimeFromTransfusion and TimeFromTransfusion<RightX then do;
    _Fraction=(TimeFromTransfusion-LeftX)/(RightX-LeftX);
    Estimate=(1-_Fraction)*LeftY+_Fraction*RightY;
    if missing(Estimate) then PointStatus='FIT_UNAVAILABLE';
    else PointStatus='AVAILABLE_LINEAR_FROM_DIRECT';
   end;
   else PointStatus='FIT_UNAVAILABLE';
  end;
  keep VitalCode SpanPercent TimeFromTransfusion GridPointId Estimate PointStatus SupportStatus;
 run;
 proc sql;
  create table &h as select g.*,s.GlobalMean,s.GlobalStd,u.Unit as NativeUnit,u.UnitStatus
   from &g g inner join &scaling s on g.VitalCode=s.VitalCode
   inner join &units u on g.VitalCode=u.VitalCode;
 quit;
 data &j;
  length LoessReportId $64 MethodId $32 GridId $48 ValueScale $16 Unit $32
   IntervalStatus $40 DisclosureStatus $40 MethodAdoptionStatus $32;
  set &h;
  LoessReportId="&report_id"; MethodId='DIRECT_LINEAR_DISPLAY_V1';
  GridId="MINUTE_&grid_min._&grid_max._STEP_&grid_step";
  IntervalStatus='NOT_EXPORTED_DESCRIPTIVE'; DisclosureStatus='REVIEW_REQUIRED';
  MethodAdoptionStatus='PROPOSAL_PENDING_APPROVAL';
  ValueScale='Z_SCORE'; Unit='SD'; output;
  ValueScale='NATIVE'; Unit=NativeUnit;
  if not missing(Estimate) then do;
   Estimate=GlobalMean+GlobalStd*Estimate;
   if missing(Estimate) then PointStatus='NATIVE_TRANSFORM_UNAVAILABLE';
  end;
  output;
  keep LoessReportId MethodId VitalCode SpanPercent GridId GridPointId TimeFromTransfusion
   ValueScale Unit UnitStatus Estimate PointStatus IntervalStatus SupportStatus DisclosureStatus MethodAdoptionStatus;
 run;
 %if &syscc ne 0 or &syserr ne 0 %then %do; %let RBC_LOESS_GRID_REASON=NATIVE_SAS_FAILURE; %goto finish; %end;
 proc sql noprint;
  select count(*) into :n trimmed from &j;
  select count(*) into :bad trimmed from
   (select VitalCode,SpanPercent,GridPointId,ValueScale,count(*) as n from &j
    group by VitalCode,SpanPercent,GridPointId,ValueScale having n ne 1);
 quit;
 %if &n ne %eval(7*(&span_max-&span_min+1)*((&grid_max-&grid_min)/&grid_step+1)*2) or &bad ne 0 %then %do;
  %let RBC_LOESS_GRID_REASON=GRID_CARDINALITY_REJECTED; %goto finish;
 %end;
 data &out; set &j; run;
 %if &syscc ne 0 or &syserr ne 0 %then %do; %let RBC_LOESS_GRID_REASON=NATIVE_SAS_FAILURE; %goto finish; %end;
 %let RBC_LOESS_GRID_OK=1; %let RBC_LOESS_GRID_REASON=PROPOSAL_GRID_COMPLETE;
 %finish:

%mend;

%macro rbl_schema(ds=,chars=,nums=);
 %local h i v k rc;
 %if not %sysfunc(exist(&ds,DATA)) or %sysfunc(exist(&ds,VIEW)) %then %do;
  %let RBC_LOESS_REPORT_REASON=SOURCE_DATA_REQUIRED; %return;
 %end;
 %let h=%sysfunc(open(&ds,i));
 %if &h=0 %then %do; %let RBC_LOESS_REPORT_REASON=SOURCE_OPEN_FAILED; %return; %end;
 %do i=1 %to %sysfunc(countw(%str( )&chars));
  %let v=%scan(&chars,&i); %let k=%sysfunc(varnum(&h,&v));
  %if &k=0 %then %let RBC_LOESS_REPORT_REASON=SOURCE_SCHEMA_INVALID;
  %else %if %sysfunc(vartype(&h,&k)) ne C %then %let RBC_LOESS_REPORT_REASON=SOURCE_SCHEMA_INVALID;
 %end;
 %do i=1 %to %sysfunc(countw(%str( )&nums));
  %let v=%scan(&nums,&i); %let k=%sysfunc(varnum(&h,&v));
  %if &k=0 %then %let RBC_LOESS_REPORT_REASON=SOURCE_SCHEMA_INVALID;
  %else %if %sysfunc(vartype(&h,&k)) ne N %then %let RBC_LOESS_REPORT_REASON=SOURCE_SCHEMA_INVALID;
 %end;
 %let rc=%sysfunc(close(&h));
%mend;

%macro rbl_cleanup(outlib=,roles=,scratch=,owned=0,published=0);
 %local oldobs oldreplace oldsyntax;
 %if not &owned and not &published %then %return;
 %let oldobs=%sysfunc(getoption(obs,keyword));
 %let oldreplace=%sysfunc(getoption(replace,keyword));
 %let oldsyntax=%sysfunc(getoption(syntaxcheck,keyword));
 options obs=max replace nosyntaxcheck;
 %if &owned %then %do; proc datasets library=work nolist; delete &scratch; quit; %end;
 %if &RBC_LOESS_REPORT_OK=1 and (&syscc ne 0 or &syserr ne 0) %then %do;
  %let RBC_LOESS_REPORT_OK=0; %let RBC_LOESS_REPORT_REASON=CLEANUP_FAILED;
 %end;
 %if &RBC_LOESS_REPORT_OK ne 1 and &published %then %do;
  proc datasets library=&outlib nolist; delete &roles; quit;
 %end;
 options &oldobs &oldreplace &oldsyntax;
%mend;

%macro rbl_spans;
 %local s; %do s=10 %to 90; %sysevalf(&s/100) %end;
%mend;
%macro rbc_loess_report(preparedlib=,outlib=,run_id=,analysis_spec_id=,
 cohort_mode=,input_snapshot_id=,code_hash=,config_hash=,preparation_receipt_hash=,
 report_run_id=,report_code_hash=,report_config_hash=);
 %global RBC_LOESS_REPORT_OK RBC_LOESS_REPORT_REASON;
 %let RBC_LOESS_REPORT_OK=0; %let RBC_LOESS_REPORT_REASON=NOT_COMPLETED;
 %local i v bad n total fraction fitn published roles scratch ds owned h k rc fastn expected_direct direct_created sparse_code smoothlist;
 %let bad=0; %let published=0; %let owned=0;
 %let roles=loess_scaling loess_timegroups loess_bernoulli loess_retained loess_direct
  loess_metadata loess_status loess_support loess_predictions;
 %let scratch=_llplan _llsrc _llscale _llz _lltgroups _llwindow _llbern _llret _llfit
  _lldirect _llpoints _llunits _llgrid _llstatus _llsupport _llmeta _llpred _llone _llfastfit _llpart;
 %if &syscc ne 0 or &syserr ne 0 %then %do; %let RBC_LOESS_REPORT_REASON=PRIOR_SAS_FAILURE; %goto done; %end;
 %do i=1 %to 2;
  %let v=%scan(preparedlib outlib,&i);
  %if %length(%superq(&v))<1 or %length(%superq(&v))>8 or not %sysfunc(nvalid(%superq(&v),V7)) %then %do;
   %let RBC_LOESS_REPORT_REASON=LIBREF_INVALID; %goto done;
  %end;
  %if %sysfunc(libref(&&&v)) ne 0 %then %do; %let RBC_LOESS_REPORT_REASON=LIBREF_UNASSIGNED; %goto done; %end;
 %end;
 %if %upcase(&preparedlib)=%upcase(&outlib) or %upcase(&outlib)=WORK %then %do;
  %let RBC_LOESS_REPORT_REASON=SEPARATE_OUTPUT_LIBRARY_REQUIRED; %goto done;
 %end;
 %do i=1 %to 2;
  %let v=%scan(run_id report_run_id,&i);
  %if %sysfunc(prxmatch(/^[0-9a-f]{32}$/,%superq(&v))) ne 1 %then %do; %let RBC_LOESS_REPORT_REASON=ID_INVALID; %goto done; %end;
 %end;
 %do i=1 %to 5;
  %let v=%scan(code_hash config_hash preparation_receipt_hash report_code_hash report_config_hash,&i);
  %if %sysfunc(prxmatch(/^[0-9a-f]{64}$/,%superq(&v))) ne 1 %then %do; %let RBC_LOESS_REPORT_REASON=HASH_INVALID; %goto done; %end;
 %end;
 %do i=1 %to 2;
  %let v=%scan(analysis_spec_id input_snapshot_id,&i);
  %if %sysfunc(prxmatch(%str(/^[A-Za-z0-9_.:-]{1,64}$/),%superq(&v))) ne 1 %then %do; %let RBC_LOESS_REPORT_REASON=CONTEXT_INVALID; %goto done; %end;
 %end;
 %if %sysfunc(prxmatch(/^(development_sample|full_cohort)$/,%superq(cohort_mode))) ne 1 %then %do; %let RBC_LOESS_REPORT_REASON=SCOPE_INVALID; %goto done; %end;
 %do i=1 %to %sysfunc(countw(&roles));
  %let v=%scan(&roles,&i);
  %if %sysfunc(exist(&outlib..&v,DATA)) or %sysfunc(exist(&outlib..&v,VIEW)) %then %do;
   %let RBC_LOESS_REPORT_REASON=OUTPUT_ALREADY_EXISTS; %goto done;
  %end;
 %end;
 %do i=1 %to %sysfunc(countw(&scratch));
  %let v=%scan(&scratch,&i);
  %if %sysfunc(exist(work.&v,DATA)) or %sysfunc(exist(work.&v,VIEW)) %then %do;
   %let RBC_LOESS_REPORT_REASON=WORK_COLLISION; %goto done;
  %end;
 %end;
 %rbl_schema(ds=&preparedlib..pipeline_identity,
 chars=RunId AnalysisSpecId CohortMode InputSnapshotId CodeHash ConfigHash ExecutionStatus DisclosureStatus,nums=);
 %rbl_schema(ds=&preparedlib..loess_prewindow,
 chars=RBC_EventKey ICUAdmissionKey VitalCode SourceWindowStatus PrewindowProtocol RunId AnalysisSpecId CohortMode PopulationId DisclosureStatus DataScope InputSnapshotId CodeHash ConfigHash,
 nums=PersonKey ClinicalPatientID TransDt Datetime TimeFromTransfusion Value AdmissionTime DischargeTime);
 %if &RBC_LOESS_REPORT_REASON ne NOT_COMPLETED %then %goto done;
 %let h=%sysfunc(open(&preparedlib..loess_prewindow,i));
 %let k=%sysfunc(varnum(&h,VitalCode));
 %if %sysfunc(varlen(&h,&k)) ne 4 %then %let bad=1;
 %let rc=%sysfunc(close(&h));
 data _null_;
  if upcase(pathname("&preparedlib"))=upcase(pathname("&outlib")) then call symputx('bad',1,'L');
 run;
 %if &bad %then %do; %let RBC_LOESS_REPORT_REASON=INPUT_LENGTH_OR_LIBRARY_ALIAS_INVALID; %goto done; %end;
 %let n=0;
 data _null_;
  set &preparedlib..pipeline_identity end=last;
  if RunId ne symget('run_id') or AnalysisSpecId ne symget('analysis_spec_id') or CohortMode ne symget('cohort_mode')
   or InputSnapshotId ne symget('input_snapshot_id') or CodeHash ne symget('code_hash') or ConfigHash ne symget('config_hash')
   or ExecutionStatus ne 'PREPARATION_COMPLETE' or DisclosureStatus ne 'PRIVATE_UNREVIEWED' then call symputx('bad',1,'L');
  if last then call symputx('n',_n_,'L');
 run;
 %if &bad or &n ne 1 %then %do; %let RBC_LOESS_REPORT_REASON=PREPARATION_IDENTITY_INVALID; %goto done; %end;
 data _null_;
  set &preparedlib..loess_prewindow;
  if RunId ne symget('run_id') or AnalysisSpecId ne symget('analysis_spec_id') or CohortMode ne symget('cohort_mode')
   or InputSnapshotId ne symget('input_snapshot_id') or CodeHash ne symget('code_hash') or ConfigHash ne symget('config_hash')
   or PopulationId ne 'PRIMARY' or DisclosureStatus ne 'PRIVATE_UNREVIEWED'
   or PrewindowProtocol ne 'PRIMARY_SOURCE_MULTIPLICITY_PREWINDOW_V1'
   or DataScope ne 'PRIMARY_AVAILABLE_SOURCE_ROWS_PREWINDOW'
   or SourceWindowStatus not in ('IN_ANALYSIS_WINDOW','WINDOW_ONLY_EXCLUDED')
   or (abs(TimeFromTransfusion)<=720 and SourceWindowStatus ne 'IN_ANALYSIS_WINDOW')
   or (abs(TimeFromTransfusion)>720 and SourceWindowStatus ne 'WINDOW_ONLY_EXCLUDED')
   or VitalCode not in ('ARTm','ARTs','ARTd','HR','FIO2','SPO2','VE')
   or cmiss(PersonKey,ClinicalPatientID,RBC_EventKey,ICUAdmissionKey,TransDt,Datetime,TimeFromTransfusion,AdmissionTime,DischargeTime)>0
   or AdmissionTime>TransDt or TransDt>DischargeTime
   or TimeFromTransfusion ne (Datetime-TransDt)/60
   or abs(Value)>constant('BIG') or abs(TimeFromTransfusion)>constant('BIG')
   then call symputx('bad',1,'L');
 run;
 %if &bad or &syscc ne 0 or &syserr ne 0 %then %do; %let RBC_LOESS_REPORT_REASON=PREWINDOW_CONTEXT_OR_VALUES_INVALID; %goto done; %end;
 %let owned=1;
 data work._llplan;
  length VitalCode $4;
  do PlotOrder=1 to 7; VitalCode=scan('ARTm ARTs ARTd HR FIO2 SPO2 VE',PlotOrder); output; end;
 run;
 proc sort data=&preparedlib..loess_prewindow(keep=VitalCode Value TimeFromTransfusion PersonKey RBC_EventKey) out=work._llsrc;
  by VitalCode;
 run;
 proc means data=work._llsrc noprint; by VitalCode; var Value;
  output out=work._llone n=NAvailable mean=GlobalMean std=GlobalStd;
 run;
 proc sql;
  create table work._llscale as select p.*,s.NAvailable,s.GlobalMean,s.GlobalStd from work._llplan p
   left join work._llone s on p.VitalCode=s.VitalCode order by p.VitalCode;
 quit;
 data work._llscale;
  length ScaleStatus $48;
  set work._llscale;
  if missing(NAvailable) then NAvailable=0;
  if NAvailable=0 then ScaleStatus='UNAVAILABLE_NO_INPUT';
  else if missing(GlobalMean) or missing(GlobalStd) or GlobalStd<=0 or abs(GlobalMean)>constant('BIG') or GlobalStd>constant('BIG')
   then ScaleStatus='UNAVAILABLE_ZERO_OR_UNDEFINED_SCALE';
  else ScaleStatus='AVAILABLE';
 run;
 data work._llz;
  merge work._llsrc(in=a) work._llscale; by VitalCode; if a;
  Value_Z=.; if ScaleStatus='AVAILABLE' and not missing(Value) then Value_Z=(Value-GlobalMean)/GlobalStd;
  if ScaleStatus='AVAILABLE' and not missing(Value) and (missing(Value_Z) or abs(Value_Z)>constant('BIG')) then call symputx('bad',1,'L');
 run;
 %if &bad or &syscc ne 0 or &syserr ne 0 %then %do; %let RBC_LOESS_REPORT_REASON=SCALE_ARITHMETIC_FAILED; %goto done; %end;
 proc sort data=work._llz; by VitalCode TimeFromTransfusion; run;
 proc means data=work._llz noprint; by VitalCode TimeFromTransfusion; var Value_Z Value;
  output out=work._lltgroups mean=Z_Mean RawMean;
 run;
 data work._llwindow;
  set work._lltgroups;
  if -720<=TimeFromTransfusion and TimeFromTransfusion<=720;
  PlotOrder=findw('ARTm ARTs ARTd HR FIO2 SPO2 VE',strip(VitalCode),' ','E');
 run;
 proc sort data=work._llwindow; by PlotOrder TimeFromTransfusion; run;
 proc sql noprint; select count(*) into :total trimmed from work._llwindow; quit;
 %let fraction=1; %if &total>50000 %then %let fraction=%sysevalf(50000/&total);
 data work._llbern;
  set work._llwindow;
  if &total>50000 then do; if ranuni(1234)<&fraction then output; end;
  else output;
 run;
 data work._llret;
  set work._llbern; by PlotOrder TimeFromTransfusion;
  if first.PlotOrder then counter=0; counter+1;
  if mod(counter,3)=0 then output; drop counter;
 run;
 proc sort data=work._llret; by VitalCode TimeFromTransfusion; run;
 proc sql;
  create table work._llstatus as select s.*,coalesce(t.NFit,0) as NFit from work._llscale s
   left join (select VitalCode,count(*) as NFit from work._llret where not missing(Z_Mean) group by VitalCode) t
   on s.VitalCode=t.VitalCode;
 quit;
 data work._llstatus;
  length LoessReportId $64 FitStatus $48 PointStatusPolicy $48;
  set work._llstatus; LoessReportId="&report_run_id";
  PointStatusPolicy='EXPLICIT_GRID_STATUS_NO_EXTRAPOLATION';

  do SpanPercent=10 to 90;
   if ScaleStatus ne 'AVAILABLE' then FitStatus=ScaleStatus;
   else if NFit*SpanPercent<300 then FitStatus='INSUFFICIENT_SUPPORT';
   else FitStatus='DIRECT_COMPLETED';
   output;
  end;
 run;
 proc sql;
  create table work._llfit as select t.* from work._llret t inner join work._llstatus s on t.VitalCode=s.VitalCode
   and s.SpanPercent=90 and s.FitStatus='DIRECT_COMPLETED' where not missing(t.Z_Mean) order by t.VitalCode,t.TimeFromTransfusion;
 quit;

 proc sql;
  create table work._llfastfit as select t.* from work._llfit t inner join work._llstatus s
   on t.VitalCode=s.VitalCode and s.SpanPercent=10 and s.FitStatus='DIRECT_COMPLETED'
   order by t.VitalCode,t.TimeFromTransfusion;
 quit;
 proc sql noprint;
  select count(*) into :fitn trimmed from work._llfit;
  select count(*) into :fastn trimmed from work._llfastfit;
  select coalesce(sum(NFit),0) into :expected_direct trimmed from work._llstatus where FitStatus='DIRECT_COMPLETED';
 quit;
 %let direct_created=0;
 %if &fastn>0 %then %do;
  ods listing; ods exclude all;
  proc loess data=work._llfastfit;
   by VitalCode;
   model Z_Mean=TimeFromTransfusion / smooth=(%rbl_spans) degree=2 alpha=.05 direct all iterations=1 scale=none;
   output out=work._lldirect p=Pred lclm=Lower uclm=Upper;
  run;
  ods exclude none;
  %if &syscc ne 0 or &syserr ne 0 %then %do; %let RBC_LOESS_REPORT_REASON=NATIVE_DIRECT_FAILED; %goto done; %end;
  %let direct_created=1;
 %end;
 %do i=1 %to 7;
  %let sparse_code=%scan(ARTm ARTs ARTd HR FIO2 SPO2 VE,&i);
  %let smoothlist=;
  proc sql noprint;
   select (SpanPercent/100) format=4.2 into :smoothlist separated by ' '
    from work._llstatus where VitalCode="&sparse_code" and NFit<30 and FitStatus='DIRECT_COMPLETED'
    order by SpanPercent;
  quit;
  %if %length(%superq(smoothlist))>0 %then %do;
   ods listing; ods exclude all;
   proc loess data=work._llfit(where=(VitalCode="&sparse_code"));
    by VitalCode;
    model Z_Mean=TimeFromTransfusion / smooth=(&smoothlist) degree=2 alpha=.05 direct all iterations=1 scale=none;
    output out=work._llpart p=Pred lclm=Lower uclm=Upper;
   run;
   ods exclude none;
   %if &syscc ne 0 or &syserr ne 0 %then %do; %let RBC_LOESS_REPORT_REASON=NATIVE_DIRECT_FAILED; %goto done; %end;
   %if &direct_created %then %do; proc append base=work._lldirect data=work._llpart; run; %end;
   %else %do; data work._lldirect;set work._llpart;run;%let direct_created=1; %end;
   %if &syscc ne 0 or &syserr ne 0 %then %do; %let RBC_LOESS_REPORT_REASON=NATIVE_DIRECT_FAILED; %goto done; %end;
  %end;
 %end;
 %if not &direct_created %then %do;
  data work._lldirect;
   length VitalCode $8 DepVar $32;length TimeFromTransfusion Z_Mean SmoothingParameter Pred Lower Upper 8;stop;
  run;
 %end;
 data work._llpoints;
  length VitalCode $8;
  set work._lldirect;
  SpanPercent=round(100*SmoothingParameter);
  if abs(Pred)>constant('BIG') or abs(Z_Mean)>constant('BIG') then call symputx('bad',1,'L');
  keep VitalCode SpanPercent TimeFromTransfusion Z_Mean Pred;
 run;
 proc sql noprint;
  select count(*) into :n trimmed from work._llpoints;
 quit;
 %if &bad or &n ne &expected_direct %then %do; %let RBC_LOESS_REPORT_REASON=NATIVE_DIRECT_UNIVERSE_INVALID; %goto done; %end;
 data work._llunits; set work._llplan; length Unit $32 UnitStatus $40; Unit='NATIVE'; UnitStatus='SOURCE_UNIT_UNCONFIRMED'; keep VitalCode Unit UnitStatus; run;
 %rbc_loess_direct_display_grid(points=work._llpoints,scaling=work._llscale,units=work._llunits,out=work._llgrid,report_id=&report_run_id);
 %if &RBC_LOESS_GRID_OK ne 1 %then %do; %let RBC_LOESS_REPORT_REASON=DISPLAY_GRID_REJECTED; %goto done; %end;
 proc sql;
  create table work._llpred as select g.*,s.FitStatus from work._llgrid g inner join work._llstatus s
   on g.VitalCode=s.VitalCode and g.SpanPercent=s.SpanPercent;
 quit;
 data work._llpred;
  retain LoessReportId MethodId VitalCode SpanPercent GridId GridPointId TimeFromTransfusion ValueScale Unit UnitStatus
   Estimate PointStatus IntervalStatus SupportStatus DisclosureStatus MethodAdoptionStatus;
  set work._llpred;
  MethodAdoptionStatus='DIRECT_DEGREE2_LOESS'; DisclosureStatus='PRIVATE_UNREVIEWED';
  if ValueScale='Z_SCORE' then UnitStatus='STANDARDIZED_GLOBAL_SD';
  if FitStatus ne 'DIRECT_COMPLETED' then do;
   Estimate=.;PointStatus=FitStatus;
   if FitStatus='INSUFFICIENT_SUPPORT' then SupportStatus='INSUFFICIENT_FITTING_SUPPORT';
   else SupportStatus='NO_RETAINED_INPUT';
  end;
  if not missing(Estimate) and abs(Estimate)>constant('BIG') then call symputx('bad',1,'L');
  keep LoessReportId MethodId VitalCode SpanPercent GridId GridPointId TimeFromTransfusion ValueScale Unit UnitStatus
   Estimate PointStatus IntervalStatus SupportStatus DisclosureStatus MethodAdoptionStatus;
 run;

 proc sql;
  create table work._llsupport as select p.VitalCode,count(s.VitalCode) as NRows,count(distinct s.PersonKey) as NKnownPersons,
   count(distinct s.RBC_EventKey) as NKnownEvents,count(s.Value) as NAvailableOutcome,count(distinct s.TimeFromTransfusion) as NExactTimeGroups
   from work._llplan p left join work._llsrc s on p.VitalCode=s.VitalCode group by p.VitalCode;
 quit;
 data work._llsupport;
  length LoessReportId $64 SupportStage $40 CountUnit $32 OverlapSemantics $48 DisclosureStatus $40;
  set work._llsupport; LoessReportId="&report_run_id"; SupportStage='GLOBAL_SCALING_SCOPE';
  CountUnit='SOURCE_ROWS'; OverlapSemantics='PERSON_EVENT_COUNTS_NONADDITIVE'; DisclosureStatus='PRIVATE_UNREVIEWED'; NRetainedTimeGroups=.;
 run;
 %do i=1 %to 4;
  %let ds=%scan(_llz _llbern _llret _llfit,&i);
  proc sql;
   create table work._llone as select p.VitalCode,count(s.VitalCode) as NRows,
   %if &i=1 %then %do; count(distinct s.PersonKey) as NKnownPersons,count(distinct s.RBC_EventKey) as NKnownEvents,count(s.Value) as NAvailableOutcome, %end;
   %else %do; . as NKnownPersons,. as NKnownEvents,sum(not missing(s.Z_Mean)) as NAvailableOutcome, %end;
   count(distinct s.TimeFromTransfusion) as NExactTimeGroups
   from work._llplan p left join work.&ds s on p.VitalCode=s.VitalCode
   %if &i=1 %then %do; and -720<=s.TimeFromTransfusion and s.TimeFromTransfusion<=720 and not missing(s.Value) %end;
   group by p.VitalCode;
  quit;
  data work._llone;
   length LoessReportId $64 SupportStage $40 CountUnit $32 OverlapSemantics $48 DisclosureStatus $40;
   set work._llone; LoessReportId="&report_run_id";
   SupportStage=scan('DISPLAY_WINDOW_AVAILABLE_OUTCOME POST_BERNOULLI POST_EVERY_THIRD ACTUAL_NONMISSING_LOESS_INPUT',&i);
   %if &i=1 %then %do; CountUnit='SOURCE_ROWS'; NRetainedTimeGroups=.; %end;
   %else %do; CountUnit='EXACT_TIME_GROUPS'; NRetainedTimeGroups=NRows; %end;
   OverlapSemantics='PERSON_EVENT_COUNTS_NONADDITIVE'; DisclosureStatus='PRIVATE_UNREVIEWED';
  run;
  proc append base=work._llsupport data=work._llone; run;
 %end;
 data work._llmeta;
  length RunId AnalysisSpecId InputSnapshotId CodeHash ConfigHash PreparationReceiptHash ReportRunId ReportCodeHash ReportConfigHash ExportId ExportCodeHash $64
   CohortMode $24 PopulationId $32 DisclosureStatus $40 LoessReportId $64 Protocol $32 MethodId $32 MethodAdoptionStatus $32
   Unit $32 UnitStatus $40 ScaleDefinition PopulationDefinition InputWeighting ExactTimeGrouping ThinningRule $64 GridId $48 IntervalStatus $40;
  set work._llplan(keep=VitalCode);
  RunId="&run_id"; AnalysisSpecId="&analysis_spec_id"; CohortMode="&cohort_mode"; InputSnapshotId="&input_snapshot_id";
  CodeHash="&code_hash"; ConfigHash="&config_hash"; PreparationReceiptHash="&preparation_receipt_hash";
  ReportRunId="&report_run_id"; ReportCodeHash="&report_code_hash"; ReportConfigHash="&report_config_hash";
  ExportId='NOT_YET_EXPORTED'; ExportCodeHash='NOT_YET_EXPORTED'; PopulationId='PRIMARY'; DisclosureStatus='PRIVATE_UNREVIEWED';
  LoessReportId=ReportRunId; Protocol='RBC_LOESS_REPORT_V1'; MethodId='DIRECT_LINEAR_DISPLAY_V1'; MethodAdoptionStatus='DIRECT_DEGREE2_LOESS';
  Unit='NATIVE'; UnitStatus='SOURCE_UNIT_UNCONFIRMED'; ScaleDefinition='PREWINDOW_SOURCE_ROW_GLOBAL_MEAN_SAMPLE_SD';
  PopulationDefinition='PRIMARY_ACCEPTED_EVENT_ADMISSION_PREWINDOW'; InputWeighting='EQUAL_RETAINED_EXACT_TIME_GROUPS';
  ExactTimeGrouping='EXACT_UNROUNDED_MINUTES'; ThinningRule='BERNOULLI_50000_SEED1234_THEN_EVERY_THIRD';
  GridId='MINUTE_-720_720_STEP_1'; IntervalStatus='NOT_EXPORTED_DESCRIPTIVE'; DefaultSpanPercent=30; SpanMin=10; SpanMax=90;
  Degree=2; Iterations=1; ThinningSeed=1234; GridMin=-720; GridMax=720; GridStep=1;
 run;
 %if &bad or &syscc ne 0 or &syserr ne 0 %then %do; %let RBC_LOESS_REPORT_REASON=STAGED_REPORT_FAILED; %goto done; %end;
 %let published=1;
 %do i=1 %to 9;
  %let v=%scan(&roles,&i); %let ds=%scan(_llscale _lltgroups _llbern _llret _lldirect _llmeta _llstatus _llsupport _llpred,&i);
  data &outlib..&v; set work.&ds;
   %if &v=loess_status %then %do; keep LoessReportId VitalCode SpanPercent FitStatus PointStatusPolicy; %end;
  run;
  %if &syscc ne 0 or &syserr ne 0 %then %do; %let RBC_LOESS_REPORT_REASON=PUBLICATION_FAILED; %goto done; %end;
 %end;
 %let RBC_LOESS_REPORT_OK=1; %let RBC_LOESS_REPORT_REASON=REPORT_COMPLETE;
 %done:
 %rbl_cleanup(outlib=&outlib,roles=&roles,scratch=&scratch,owned=&owned,published=&published);
%mend;

