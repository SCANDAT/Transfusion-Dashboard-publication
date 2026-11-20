/* Mixed-effects models.
   Native spline and class design, complete cases, reference profiles, REML random-intercept fitting, same-fit prediction and contrasts. Native working-model uncertainty is not the final robust inference.
   This file defines macros; use run.py to execute the analysis steps.
*/
%macro rbc_fit_fail(message);
    %put ERROR: RBC_FIT_GUARD: &message;
    %abort cancel;
%mend;

%macro rbc_fit_check_sas(stage=UNSPECIFIED);
    %if &syserr > 4 or &syscc > 4 %then %do;
         
        %put NOTE: RBC_FIT_SYSTEM_STATUS &stage SYSERR=&syserr SYSCC=&syscc;
        %rbc_fit_fail(A preceding SAS step failed. Job cannot be completed.);
    %end;
%mend;

%macro rbc_fit_require(data=, variables=, kind=N);
    %local handle rc i variable position actual;
    %let handle=%sysfunc(open(&data,i));
    %if &handle=0 %then %rbc_fit_fail(Required input table cannot be opened.);
    %do i=1 %to %sysfunc(countw(&variables,%str( )));
        %let variable=%scan(&variables,&i,%str( ));
        %let position=%sysfunc(varnum(&handle,&variable));
        %if &position=0 %then %do;
            %let rc=%sysfunc(close(&handle));
            %rbc_fit_fail(Required variable &variable is absent.);
        %end;
        %let actual=%sysfunc(vartype(&handle,&position));
        %if &actual ne &kind %then %do;
            %let rc=%sysfunc(close(&handle));
            %rbc_fit_fail(Variable &variable has the wrong type.);
        %end;
    %end;
    %let rc=%sysfunc(close(&handle));
%mend;

%macro rbc_native_effects(adjustment=FULL,knots=,details=,basis=NATURALCUBIC);
    %local variables effects k variable effect handle rc number value knotlist basis_option;
    %let basis_option=naturalcubic;
    %if %upcase(&basis)=TPF %then %let basis_option=basis=tpf;
    %else %if %upcase(&basis) ne NATURALCUBIC %then %rbc_fit_fail(Unsupported native spline basis request.);
    %let variables=TimeFromTransfusion PatientAge ICU_time;
    %let effects=spl_time spl_age spl_icu;
    %if %upcase(&adjustment)=FULL %then %do;
        %let variables=&variables Crystalloid_1 Crystalloid_24 Pressors_1 Pressors_24;
        %let effects=&effects spl_cryst1 spl_cryst24 spl_press1 spl_press24;
    %end;
    %do k=1 %to %sysfunc(countw(&variables));
        %let variable=%scan(&variables,&k);
        %let effect=%scan(&effects,&k);
        %if %length(%superq(knots))=0 %then %do;
             
            %if &k=1 %then %do;
                effect &effect=spline(&variable / &basis_option &details
                    knotmethod=list(-660 -360 -60 0 60 360 660));
            %end;
            %else %do;
                effect &effect=spline(&variable / &basis_option &details knotmethod=percentiles(3));
            %end;
        %end;
        %else %do;
            %let knotlist=;
            %let handle=%sysfunc(open(&knots(where=(VariableName="&variable")),i));
            %if &handle=0 %then %rbc_fit_fail(Frozen spline-knot archive cannot be opened.);
            %let number=%sysfunc(varnum(&handle,KnotValue));
            %if &number=0 %then %rbc_fit_fail(Frozen spline-knot schema is invalid.);
            %let rc=%sysfunc(fetch(&handle));
            %do %while(&rc=0);
                %let value=%sysfunc(getvarn(&handle,&number),best32.);
                %let knotlist=&knotlist &value;
                %let rc=%sysfunc(fetch(&handle));
            %end;
            %let rc=%sysfunc(close(&handle));
            %if (&k=1 and %sysfunc(countw(&knotlist,%str( ))) ne 7) or
                (&k>1 and %sysfunc(countw(&knotlist,%str( ))) ne 3) %then
                %rbc_fit_fail(Frozen spline archive has the wrong native knot count.);
            effect &effect=spline(&variable / &basis_option &details knotmethod=list(&knotlist));
        %end;
    %end;
%mend;

%macro rbc_fit_freeze_knots(outlib=,job_id=,adjustment=FULL,on_error=ABORT);
    %local expected bad support_vars support_effects support_count constants insufficient;
    %global RBC_NATIVE_KNOTS_OK RBC_NATIVE_KNOTS_REASON;
    %let RBC_NATIVE_KNOTS_OK=0;
    %let RBC_NATIVE_KNOTS_REASON=NOT_VALIDATED;
    %if %upcase(&on_error) ne ABORT and %upcase(&on_error) ne RETURN %then
        %rbc_fit_fail(Native knot error mode must be ABORT or RETURN.);
    %let expected=3;
    %let support_vars=PatientAge ICU_time;
    %let support_effects=spl_age spl_icu;
    %if %upcase(&adjustment)=FULL %then %do;
        %let expected=7;
        %let support_vars=&support_vars Crystalloid_1 Crystalloid_24 Pressors_1 Pressors_24;
        %let support_effects=&support_effects spl_cryst1 spl_cryst24 spl_press1 spl_press24;
    %end;
    %let support_count=%sysfunc(countw(&support_vars));

    data &outlib..&job_id._spline_support;
        length VariableName EffectName $32 SupportStatus $24;
        array X{&support_count} &support_vars;
        array FirstValue{&support_count} _temporary_;
        array SecondValue{&support_count} _temporary_;
        array DistinctCount{&support_count} _temporary_;
        do j=1 to &support_count; DistinctCount{j}=0; end;
        AllSufficient=0;
        do until(Last or AllSufficient);
            set work._rbc_real(keep=&support_vars) end=Last;
            AllSufficient=1;
            do j=1 to &support_count;
                if not missing(X{j}) then do;
                    if DistinctCount{j}=0 then do;
                        FirstValue{j}=X{j}; DistinctCount{j}=1;
                    end;
                    else if DistinctCount{j}=1 and X{j} ne FirstValue{j} then do;
                        SecondValue{j}=X{j}; DistinctCount{j}=2;
                    end;
                    else if DistinctCount{j}=2 and X{j} ne FirstValue{j}
                        and X{j} ne SecondValue{j} then DistinctCount{j}=3;
                end;
                if DistinctCount{j}<3 then AllSufficient=0;
            end;
        end;
        do j=1 to &support_count;
            VariableName=scan("&support_vars",j,' ');
            EffectName=scan("&support_effects",j,' ');
            NDistinctCappedAt3=DistinctCount{j};
            if NDistinctCappedAt3<=1 then SupportStatus='CONSTANT_OR_EMPTY';
            else if NDistinctCappedAt3=2 then SupportStatus='FEWER_THAN_THREE';
            else SupportStatus='ENOUGH_DISTINCT';
            output;
        end;
        keep VariableName EffectName NDistinctCappedAt3 SupportStatus;
        stop;
    run;
    proc sql noprint;
        select sum(NDistinctCappedAt3<=1),sum(NDistinctCappedAt3<3)
            into :constants trimmed,:insufficient trimmed
        from &outlib..&job_id._spline_support;
    quit;
    %rbc_fit_check_sas(stage=SPLINE_SUPPORT);
    %if &insufficient>0 %then %do;
        %let RBC_NATIVE_KNOTS_REASON=INSUFFICIENT_DISTINCT_COVARIATE_REQUIRES_DECISION;
        %if &constants>0 %then %let RBC_NATIVE_KNOTS_REASON=CONSTANT_COVARIATE_REQUIRES_DECISION;
        %put NOTE: RBC_NATIVE_KNOTS_REJECTED &RBC_NATIVE_KNOTS_REASON;
        %if %upcase(&on_error)=RETURN %then %return;
        %rbc_fit_fail(Insufficient distinct adjustment values require an explicit scientific decision.);
    %end;
    ods exclude all;
    ods output SplineKnots=&outlib..&job_id._knots_native;
    proc glimmix data=work._rbc_real nofit;
        %rbc_native_effects(adjustment=&adjustment,details=details,basis=TPF);
        model Value=spl_time spl_age spl_icu
            %if %upcase(&adjustment)=FULL %then %do;
                spl_cryst1 spl_cryst24 spl_press1 spl_press24
            %end;
            / dist=normal link=identity;
    run;
    ods output close;
    ods exclude none;
    %rbc_fit_check_sas(stage=KNOT_DISCOVERY);
    %rbc_fit_require(data=&outlib..&job_id._knots_native,
        variables=ConstructedEffect,kind=C);
    %rbc_fit_require(data=&outlib..&job_id._knots_native,
        variables=KnotNumber TimeFromTransfusion PatientAge ICU_time
            %if %upcase(&adjustment)=FULL %then %do;
                Crystalloid_1 Crystalloid_24 Pressors_1 Pressors_24
            %end;,kind=N);
    data &outlib..&job_id._knots;
        set &outlib..&job_id._knots_native;
        length EffectName VariableName $32 Basis $16 KnotSource $32 BoundaryRole $8;
        EffectName=strip(ConstructedEffect); Basis='NATURALCUBIC';
        KnotSource='REAL_COMPLETE_CASE_NATIVE_SAS';
        select (upcase(EffectName));
            when ('SPL_TIME') do; VariableName='TimeFromTransfusion'; KnotValue=TimeFromTransfusion; ExpectedKnots=7; KnotSource='FIXED_TIME_SPECIFICATION'; end;
            when ('SPL_AGE') do; VariableName='PatientAge'; KnotValue=PatientAge; ExpectedKnots=3; end;
            when ('SPL_ICU') do; VariableName='ICU_time'; KnotValue=ICU_time; ExpectedKnots=3; end;
            %if %upcase(&adjustment)=FULL %then %do;
                when ('SPL_CRYST1') do; VariableName='Crystalloid_1'; KnotValue=Crystalloid_1; ExpectedKnots=3; end;
                when ('SPL_CRYST24') do; VariableName='Crystalloid_24'; KnotValue=Crystalloid_24; ExpectedKnots=3; end;
                when ('SPL_PRESS1') do; VariableName='Pressors_1'; KnotValue=Pressors_1; ExpectedKnots=3; end;
                when ('SPL_PRESS24') do; VariableName='Pressors_24'; KnotValue=Pressors_24; ExpectedKnots=3; end;
            %end;
            otherwise do;
                put 'ERROR: RBC_FIT_GUARD: Native spline-knot effect mapping is unsupported.';
                abort cancel;
            end;
        end;
        BoundaryRole='INTERNAL';
        if KnotNumber=1 then BoundaryRole='LOWER';
        if KnotNumber=ExpectedKnots then BoundaryRole='UPPER';
        keep EffectName VariableName Basis KnotSource BoundaryRole KnotNumber KnotValue ExpectedKnots;
        format KnotValue best32.;
    run;
    proc sql noprint;
        select count(distinct EffectName) into :bad trimmed from &outlib..&job_id._knots;
    quit;
    %if &bad ne &expected %then %rbc_fit_fail(Native spline-knot effect set is incomplete.);
    proc sql noprint;
        select count(*) into :bad trimmed from
            (select EffectName from &outlib..&job_id._knots group by EffectName
             having count(*) ne max(ExpectedKnots)
                or count(distinct KnotValue) ne max(ExpectedKnots)
                or count(distinct KnotNumber) ne max(ExpectedKnots)
                or min(KnotNumber) ne 1 or max(KnotNumber) ne max(ExpectedKnots)
                or sum(missing(KnotValue))>0);
    quit;
    %rbc_fit_check_sas(stage=KNOT_VALIDATION);
    %if &bad ne 0 %then %do;
        %let RBC_NATIVE_KNOTS_REASON=DEGENERATE_NATIVE_KNOTS_REQUIRES_DECISION;
        %if %upcase(&on_error)=RETURN %then %do;
            %put NOTE: RBC_NATIVE_KNOTS_REJECTED DEGENERATE_NATIVE_KNOTS_REQUIRES_DECISION;
            %return;
        %end;
        %rbc_fit_fail(Degenerate native adjustment spline knots require an explicit scientific decision.);
    %end;
    proc sort data=&outlib..&job_id._knots;
        by EffectName KnotNumber;
    run;
    %rbc_fit_check_sas(stage=KNOT_SORT);
    %let RBC_NATIVE_KNOTS_OK=1;
    %let RBC_NATIVE_KNOTS_REASON=VALIDATED_DISTINCT_NATIVE_KNOTS;
%mend;

%macro rbc_native_terms(factor=NONE,adjustment=FULL);
    %if %upcase(&factor)=NONE %then %do; spl_time %end;
    %else %do; spl_time | &factor %end;
    spl_age spl_icu RBC_Count PatientSex WardName
    %if %upcase(&adjustment)=FULL %then %do;
        spl_cryst1 spl_cryst24 spl_press1 spl_press24
        Sedatives_1_bin Sedatives_24_bin
    %end;
%mend;

%macro rbc_fit_scratch_names;
    _rbc_inputcols _rbc_scope _rbc_real _rbc_categories _rbc_means _rbc_ward
    _rbc_plannedcat _rbc_scopecat
    _rbc_score _rbc_both _rbc_design _rbc_columns _rbc_requests
    _rbc_predictions _rbc_results _rbc_holm _rbc_curve
    _rbc_endpoint_check _rbc_anchor_levels _rbc_cov_offdiag _rbc_nobs_long
%mend;

%macro rbc_fit_clear_scratch;
    proc datasets library=work nolist;
        delete %rbc_fit_scratch_names;
    quit;
%mend;

%macro rbc_fit_check_nobs(data=,schema=,expected_read=,expected_used=);
    %local char_count read_matches used_matches read_distinct used_distinct
        read_value used_value;
    %if not %sysfunc(exist(&data)) %then %rbc_fit_fail(HPMIXED NObs output is missing.);
    proc contents data=&data out=&schema(keep=name label type varnum) noprint;
    run;
    proc sql noprint;
        select count(*) into :char_count trimmed from &schema where type=2;
    quit;
    data work._rbc_nobs_long;
        set &data;
        array NObsNumbers {*} _numeric_;
        %if &char_count>0 %then %do;
            array NObsCharacters {*} _character_;
        %end;
        length CountKind $4 Binding $40 SemanticLabel $200 NumericName $32;
        NumericCount=0; NumericValue=.;
        do j=1 to dim(NObsNumbers);
            if not missing(NObsNumbers{j}) then do;
                NumericCount+1; NumericValue=NObsNumbers{j};
            end;
            SemanticLabel=compress(upcase(vlabel(NObsNumbers{j})),,'ka');
            NumericName=upcase(vname(NObsNumbers{j}));
            CountKind='';
            if SemanticLabel='NUMBEROFOBSERVATIONSREAD' or NumericName='NOBSREAD'
                then CountKind='READ';
            else if SemanticLabel='NUMBEROFOBSERVATIONSUSED' or NumericName='NOBSUSED'
                then CountKind='USED';
            if not missing(CountKind) and not missing(NObsNumbers{j}) then do;
                CountValue=NObsNumbers{j}; Binding='Numeric column semantic'; output;
            end;
        end;
        %if &char_count>0 %then %do;

            if NumericCount=1 then do j=1 to dim(NObsCharacters);
                SemanticLabel=compress(upcase(NObsCharacters{j}),,'ka');
                CountKind='';
                if SemanticLabel='NUMBEROFOBSERVATIONSREAD' then CountKind='READ';
                else if SemanticLabel='NUMBEROFOBSERVATIONSUSED' then CountKind='USED';
                if not missing(CountKind) then do;
                    CountValue=NumericValue; Binding='Long row semantic'; output;
                end;
            end;
        %end;
        keep CountKind CountValue Binding;
    run;
    proc sql noprint;
        select count(*),count(distinct CountValue),min(CountValue)
        into :read_matches trimmed,:read_distinct trimmed,:read_value trimmed
        from work._rbc_nobs_long where CountKind='READ';
        select count(*),count(distinct CountValue),min(CountValue)
        into :used_matches trimmed,:used_distinct trimmed,:used_value trimmed
        from work._rbc_nobs_long where CountKind='USED';
    quit;
    %rbc_fit_check_sas(stage=CHECK_01);
    %if &read_matches=0 or &used_matches=0 or &read_distinct ne 1 or &used_distinct ne 1 %then
        %rbc_fit_fail(Unrecognised or ambiguous HPMIXED NObs schema. Inspect the archived schema and the documented HPMIXED output columns.);
    %if &read_value ne &expected_read or &used_value ne &expected_used %then
        %rbc_fit_fail(HPMIXED observation counts differ from the explicit input contract.);
%mend;

%macro rbc_fit_bind_outputs(outlib=,job_id=,roles=);
    %local members member i identity_names drop_names j identity_field role;
    %if not %sysfunc(exist(&outlib..&job_id._identity)) %then
        %rbc_fit_fail(Model archive identity is missing.);
    proc sql noprint;
        select upcase(name) into :identity_names separated by ' '
        from dictionary.columns
        where libname=upcase("&outlib") and memname=upcase("&job_id._identity");
        %if %length(%superq(roles))=0 %then %do;
            select memname into :members separated by ' '
            from dictionary.tables
            where libname=upcase("&outlib") and memtype='DATA'
                and substr(memname,1,length("&job_id._"))=upcase("&job_id._")
                and memname ne upcase("&job_id._identity") order by memname;
        %end;
    quit;

    %if %length(%superq(roles))>0 %then %do;
        %let members=;
        %do i=1 %to %sysfunc(countw(%superq(roles),%str( )));
            %let role=%qscan(%superq(roles),&i,%str( ));
            %if not %sysfunc(nvalid(%superq(role),V7)) or %upcase(%superq(role))=IDENTITY
                or %length(&job_id._&role)>32 %then
                %rbc_fit_fail(Explicit identity-binding role is invalid.);

            %let role=%unquote(%superq(role));
            %let member=&job_id._&role;
            %if not %sysfunc(exist(&outlib..&member,DATA)) or
                %sysfunc(exist(&outlib..&member,VIEW)) %then
                %rbc_fit_fail(Explicit identity-binding DATA member is missing.);
            %do j=1 %to %sysfunc(countw(%superq(members),%str( )));
                %if %upcase(%scan(&members,&j,%str( )))=%upcase(&member) %then
                    %rbc_fit_fail(Explicit identity-binding roles are duplicated.);
            %end;
            %let members=&members &member;
        %end;
    %end;
    %do i=1 %to %sysfunc(countw(&members));
        %let member=%scan(&members,&i);
        %let drop_names=;
        proc sql noprint;
            select name into :drop_names separated by ' '
            from dictionary.columns
            where libname=upcase("&outlib") and memname=upcase("&member")
                and findw("&identity_names",strip(upcase(name)),' ')>0;
        quit;

        %if %length(%superq(drop_names))>0 %then %do;
            data _null_;
                if _n_=1 then set &outlib..&job_id._identity(keep=&drop_names rename=(
                    %do j=1 %to %sysfunc(countw(&drop_names));
                        %let identity_field=%scan(&drop_names,&j);
                        &identity_field=_RBCB_&identity_field
                    %end;
                ));
                set &outlib..&member(keep=&drop_names);
                %do j=1 %to %sysfunc(countw(&drop_names));
                    %let identity_field=%scan(&drop_names,&j);
                    if &identity_field ne _RBCB_&identity_field then do;
                        put 'ERROR: RBC_FIT_GUARD: Existing model archive identity conflicts with its binding context.';
                        abort cancel;
                    end;
                %end;
            run;
            %rbc_fit_check_sas(stage=ARCHIVE_IDENTITY_IMMUTABLE);
        %end;
        data &outlib..&member;
            if _n_=1 then set &outlib..&job_id._identity;
            set &outlib..&member
                %if %length(%superq(drop_names))>0 %then %do; (drop=&drop_names) %end;
            ;
        run;
        %rbc_fit_check_sas(stage=ARCHIVE_IDENTITY_BINDING);
    %end;
%mend;

%macro rbc_fit_optimizer_attempt(outlib=,job_id=,attempt=,xvars=,n_categories=,starts=);
    %global RBC_OPT_SYSERR RBC_OPT_SYSCC;
    %local diag_hpresent diag_hrows diag_hschema diag_hid diag_iv diag_ov diag_rc
           diag_runtime_rows diag_status_rows diag_status;
    ods exclude all;
    ods output ParameterEstimates=&outlib..&job_id._&attempt._solution
        CovParms=&outlib..&job_id._&attempt._covparms
        ConvergenceStatus=&outlib..&job_id._&attempt._convergence
        IterHistory=&outlib..&job_id._&attempt._history
        FitStatistics=&outlib..&job_id._&attempt._fitstats
        NObs=&outlib..&job_id._&attempt._nobs
        Estimates=&outlib..&job_id._&attempt._estimates
        %if &n_categories>1 %then %do;
            Contrasts=&outlib..&job_id._&attempt._omnibus_raw
            Coef=&outlib..&job_id._&attempt._coef
        %end;
    ;
    proc hpmixed data=work._rbc_design method=reml noclprint itdetails;
        nloptions tech=newrap gconv=1e-10 absgconv=1e-8 fconv=0 absfconv=0 maxiter=200
            %if %length(%superq(starts))>0 %then %do; maxfunc=125 %end; ;
        class PatientID;
        model Value=&xvars / noint solution ddfm=residual;
        random intercept / subject=PatientID;
        %if %length(%superq(starts))>0 %then %do;
            parms / parmsdata=&starts;
        %end;
        %include rbcest;
        output out=work._rbc_&attempt._predictions pred(noblup)=Predicted
            stderr(noblup)=StdErr lcl(noblup)=Lower ucl(noblup)=Upper;
    run;
    %let RBC_OPT_SYSERR=&syserr;
    %let RBC_OPT_SYSCC=&syscc;
    ods output close;
    ods exclude none;

    %let diag_hpresent=%sysfunc(exist(&outlib..&job_id._&attempt._history));
    %let diag_hrows=0; %let diag_hschema=0;
    %if &diag_hpresent=1 %then %do;
        %let diag_hid=%sysfunc(open(&outlib..&job_id._&attempt._history,i));
        %if &diag_hid>0 %then %do;
            %let diag_hrows=%sysfunc(attrn(&diag_hid,NLOBS));
            %let diag_iv=%sysfunc(varnum(&diag_hid,Iteration));
            %let diag_ov=%sysfunc(varnum(&diag_hid,Objective));
            %if &diag_iv>0 and &diag_ov>0 %then %do;
                %if %sysfunc(vartype(&diag_hid,&diag_iv))=N and
                    %sysfunc(vartype(&diag_hid,&diag_ov))=N %then %let diag_hschema=1;
            %end;
            %let diag_rc=%sysfunc(close(&diag_hid));
        %end;
    %end;
    data &outlib..&job_id._&attempt._runtime;
        set &outlib..&job_id._identity;
        length DiagnosticProtocol $48 OptimizerStage $1;
        DiagnosticProtocol='RBC_OPTIMIZER_RUNTIME_V1';
        OptimizerStage="&attempt";
        ProcedureSysErr=&RBC_OPT_SYSERR;
        ProcedureSysCC=&RBC_OPT_SYSCC;
        DiagnosticHistoryRequested=1;
        HistoryPresent=&diag_hpresent;
        HistoryRows=&diag_hrows;
        HistorySchemaValid=&diag_hschema;
        MaxFuncExplicit=(%length(%superq(starts))>0);
        RequestedMaxFunc=.;
        if MaxFuncExplicit then RequestedMaxFunc=125;
    run;
    %rbc_fit_check_sas(stage=OPTIMIZER_RUNTIME_WRITE);
    proc sql noprint;
        select count(*) into :diag_runtime_rows trimmed
        from &outlib..&job_id._&attempt._runtime;
    quit;
    %rbc_fit_check_sas(stage=OPTIMIZER_RUNTIME_COUNT);
    %if &diag_runtime_rows ne 1 %then
        %rbc_fit_fail(Optimizer runtime metadata must contain one bound row.);
    %rbc_fit_require(data=&outlib..&job_id._&attempt._convergence,variables=Status,kind=N);
    proc sql noprint;
        select count(*),max(Status) into :diag_status_rows trimmed,:diag_status trimmed
        from &outlib..&job_id._&attempt._convergence;
    quit;
    %rbc_fit_check_sas(stage=OPTIMIZER_HISTORY_CONTEXT);
    %if &diag_status_rows ne 1 or %sysevalf(&diag_status=.,boolean) %then
        %rbc_fit_fail(Optimizer diagnostic convergence context is invalid.);
    %if &diag_hpresent=1 and (&diag_hschema ne 1 or &diag_hrows<0) %then
        %rbc_fit_fail(Optimizer history schema is invalid.);

    %if &diag_status ne 0 or %length(%superq(starts))>0 %then %do;
        %if &diag_hpresent ne 1 or &diag_hrows<1 %then
            %rbc_fit_fail(Stalled or restarted optimizer diagnostic requires history.);
    %end;
%mend;

%macro rbc_fit_restart_path(outlib=,job_id=,xvars=,n_categories=,run_id=);
    %local primary_syserr primary_syscc primary_status primary_rows retry_eligible
           selected attempt_list i suffix n_start distinct_start bad_start
           restart_syserr restart_syscc restart_rows restart_status;
    %rbc_fit_optimizer_attempt(outlib=&outlib,job_id=&job_id,attempt=p,
        xvars=&xvars,n_categories=&n_categories);
    %let primary_syserr=&RBC_OPT_SYSERR; %let primary_syscc=&RBC_OPT_SYSCC;

    %rbc_fit_bind_outputs(outlib=&outlib,job_id=&job_id);
    %if &primary_syserr ne 0 or &primary_syscc ne 0 %then
        %rbc_fit_fail(Optimizer restart requires a clean primary SAS procedure status.);
    %rbc_fit_require(data=&outlib..&job_id._p_convergence,variables=Status,kind=N);
    %rbc_fit_require(data=&outlib..&job_id._p_convergence,variables=Reason,kind=C);
    proc sql noprint;
        select count(*),max(Status) into :primary_rows trimmed,:primary_status trimmed
        from &outlib..&job_id._p_convergence;
    quit;
    %if &primary_rows ne 1 or %sysevalf(&primary_status=.,boolean) %then
        %rbc_fit_fail(Primary optimizer convergence metadata is invalid.);
    %let retry_eligible=0;
    data &outlib..&job_id._optimizer_attempts;
        if _n_=1 then set &outlib..&job_id._identity;
        set &outlib..&job_id._p_convergence(keep=Status Reason);
        length OptimizerAttemptId ParentOptimizerAttemptId $64 Technique $12
               StartPolicy $40 TriggerClass $40 _RBC_ReasonTokens $512;
        OptimizerAttemptId=cats("&run_id",'.',"&job_id",'.P');
        ParentOptimizerAttemptId=''; AttemptNumber=1; Technique='NEWRAP';
        StartPolicy='DEFAULT_START'; TriggerClass='NONE';
        _RBC_ReasonTokens=prxchange('s/[^A-Z]+/ /',-1,upcase(Reason));
        RestartEligible=(Status=1 and findw(_RBC_ReasonTokens,'OPTIMIZATION',' ')>0
            and (findw(_RBC_ReasonTokens,'NOT',' ')>0 or findw(_RBC_ReasonTokens,'CANNOT',' ')>0)
            and findw(_RBC_ReasonTokens,'IMPROVE',' ')>0
            and findw(_RBC_ReasonTokens,'FUNCTION',' ')>0
            and findw(_RBC_ReasonTokens,'HESSIAN',' ')=0
            and findw(_RBC_ReasonTokens,'ITERATION',' ')=0
            and findw(_RBC_ReasonTokens,'GCONV',' ')=0
            and findw(_RBC_ReasonTokens,'FCONV',' ')=0);
        if RestartEligible then TriggerClass='FUNCTION_IMPROVEMENT_STALL';
        else if Status ne 0 then TriggerClass='UNRECOGNIZED_NONCONVERGENCE';
        call symputx('retry_eligible',RestartEligible,'L');
        ConvergenceStatusValue=Status; SelectedForFitChecks=(Status=0);
        ProcedureSysErr=&primary_syserr; ProcedureSysCC=&primary_syscc;
        GConv=1e-10; AbsGConv=1e-8; FConv=0; AbsFConv=0; MaxIter=200; MaxFunc=125;
        CovParmsPresent=%sysfunc(exist(&outlib..&job_id._p_covparms));
        ConvergencePresent=1; SolutionPresent=%sysfunc(exist(&outlib..&job_id._p_solution));
        FitStatsPresent=%sysfunc(exist(&outlib..&job_id._p_fitstats));
        NObsPresent=%sysfunc(exist(&outlib..&job_id._p_nobs));
        drop Status Reason _RBC_ReasonTokens;
    run;
    %let selected=p;
    %if &primary_status ne 0 %then %do;
        %if &retry_eligible ne 1 %then
            %rbc_fit_fail(Primary nonconvergence is not an eligible optimizer restart.);
        %rbc_fit_require(data=&outlib..&job_id._p_covparms,variables=CovParm Subject,kind=C);
        %rbc_fit_require(data=&outlib..&job_id._p_covparms,variables=Estimate,kind=N);
        proc sql noprint;
            select count(*),count(distinct CovParm),
                sum(missing(Estimate) or
                    (CovParm='Intercept' and (Subject ne 'PatientID' or Estimate<0)) or
                    (CovParm='Residual' and (not missing(Subject) or Estimate<=0)) or
                    CovParm not in ('Intercept','Residual'))
                into :n_start trimmed,:distinct_start trimmed,:bad_start trimmed
            from &outlib..&job_id._p_covparms;
        quit;
        %if &n_start ne 2 or &distinct_start ne 2 or &bad_start ne 0 %then
            %rbc_fit_fail(Primary covariance estimates are not valid named restart values.);
         
        data &outlib..&job_id._restart_starts;
            if _n_=1 then set &outlib..&job_id._identity;
            set &outlib..&job_id._p_covparms(keep=CovParm Subject Estimate);
            StartOrder=_n_;
        run;
        %rbc_fit_optimizer_attempt(outlib=&outlib,job_id=&job_id,attempt=r,
            xvars=&xvars,n_categories=&n_categories,starts=&outlib..&job_id._restart_starts);
        %let restart_syserr=&RBC_OPT_SYSERR; %let restart_syscc=&RBC_OPT_SYSCC;
        %rbc_fit_bind_outputs(outlib=&outlib,job_id=&job_id);
        %if &restart_syserr ne 0 or &restart_syscc ne 0 %then
            %rbc_fit_fail(Optimizer restart returned a SAS warning or error status.);
        %rbc_fit_require(data=&outlib..&job_id._r_convergence,variables=Status,kind=N);
        proc sql noprint;
            select count(*),max(Status) into :restart_rows trimmed,:restart_status trimmed
            from &outlib..&job_id._r_convergence;
        quit;
        %if &restart_rows ne 1 or %sysevalf(&restart_status=.,boolean) %then
            %rbc_fit_fail(Restart convergence metadata is invalid.);
        data work._rbc_optimizer_retry;
            if _n_=1 then set &outlib..&job_id._identity;
            set &outlib..&job_id._r_convergence(keep=Status);
            length OptimizerAttemptId ParentOptimizerAttemptId $64 Technique $12 StartPolicy $40 TriggerClass $40;
            OptimizerAttemptId=cats("&run_id",'.',"&job_id",'.R');
            ParentOptimizerAttemptId=cats("&run_id",'.',"&job_id",'.P');
            AttemptNumber=2; Technique='NEWRAP'; StartPolicy='PRIMARY_EMITTED_COVPARM_ORDER';
            TriggerClass='FUNCTION_IMPROVEMENT_STALL'; RestartEligible=0;
            ConvergenceStatusValue=Status; SelectedForFitChecks=(Status=0);
            ProcedureSysErr=&restart_syserr; ProcedureSysCC=&restart_syscc;
            GConv=1e-10; AbsGConv=1e-8; FConv=0; AbsFConv=0; MaxIter=200; MaxFunc=125;
            CovParmsPresent=%sysfunc(exist(&outlib..&job_id._r_covparms));
            ConvergencePresent=1; SolutionPresent=%sysfunc(exist(&outlib..&job_id._r_solution));
            FitStatsPresent=%sysfunc(exist(&outlib..&job_id._r_fitstats));
            NObsPresent=%sysfunc(exist(&outlib..&job_id._r_nobs));
            drop Status;
        run;
        proc append base=&outlib..&job_id._optimizer_attempts data=work._rbc_optimizer_retry;
        run;
        proc datasets library=work nolist;delete _rbc_optimizer_retry;quit;
        %if &restart_status ne 0 %then %rbc_fit_fail(One permitted optimizer restart did not converge.);
        %let selected=r;
    %end;

    %let attempt_list=solution covparms convergence fitstats nobs estimates;
    %if &n_categories>1 %then %let attempt_list=&attempt_list omnibus_raw coef;
    %do i=1 %to %sysfunc(countw(&attempt_list));
        %let suffix=%scan(&attempt_list,&i);
        %if not %sysfunc(exist(&outlib..&job_id._&selected._&suffix)) %then
            %rbc_fit_fail(Selected optimizer attempt lacks a required model table.);
        data &outlib..&job_id._&suffix;
            set &outlib..&job_id._&selected._&suffix;
        run;
    %end;
    data work._rbc_predictions;
        set work._rbc_&selected._predictions;
    run;
    proc datasets library=work nolist;delete _rbc_p_predictions _rbc_r_predictions;quit;
    %rbc_fit_check_sas(stage=OPTIMIZER_RESTART_SELECTION);
%mend;

%macro rbc_fit_job(data=,outlib=,job_id=,vital=,factor=NONE,adjustment=FULL,
                   score_subject=-1,keep_scratch=0,preflight_only=0,
                   run_id=,analysis_spec_id=,cohort_mode=,population_id=,fit_id=,
                   input_snapshot_id=,code_hash=,config_hash=,design_id=,profile_id=,optimizer_restart=NONE);
    %local adjust factor_none required_num existing n_scope n_used n_patients
        n_events n_categories n_score n_anchors n_pairs n_estimates n_columns
        xvars category_values reference_sex_count sentinel_count bad score_count
        coefficient_count before_time after_time model_suffixes i member n_rows
        scratch_members n_distinct min_key max_key residual_df
        identity_args identity_arg identity_value identity_index subject_key_source
        n_input planned_codes planned_k unavailable_reason admission_handle admission_pos
        admission_available n_admissions admission_status;
    %global RBC_FIT_STATUS RBC_FIT_REASON;
    %let RBC_FIT_STATUS=RUNNING; %let RBC_FIT_REASON=NONE;
    %let optimizer_restart=%upcase(%superq(optimizer_restart));
    %if &optimizer_restart ne NONE and &optimizer_restart ne NEWRAP_ONCE %then
        %rbc_fit_fail(Unsupported optimizer restart policy.);
    %let identity_args=run_id analysis_spec_id population_id fit_id input_snapshot_id design_id profile_id;
    %do identity_index=1 %to %sysfunc(countw(&identity_args));
        %let identity_arg=%scan(&identity_args,&identity_index);
        %let identity_value=%superq(&identity_arg);
        %if %length(%superq(identity_value))=0 or %length(%superq(identity_value))>128 %then
            %rbc_fit_fail(Required model identity is missing or exceeds its fixed length.);
        %if %sysfunc(prxmatch(%str(/^[A-Za-z0-9][A-Za-z0-9_.:-]*$/),%superq(identity_value))) ne 1 %then
            %rbc_fit_fail(Model identity contains unsupported characters.);
    %end;
    %if %sysfunc(prxmatch(%str(/^[0-9A-Fa-f]{32}$/),%superq(run_id))) ne 1 %then
        %rbc_fit_fail(Run identity must be a 32 digit hexadecimal identifier.);
    %if %sysfunc(prxmatch(%str(/^[0-9A-Fa-f]{64}$/),%superq(code_hash))) ne 1 or
        %sysfunc(prxmatch(%str(/^[0-9A-Fa-f]{64}$/),%superq(config_hash))) ne 1 %then
        %rbc_fit_fail(Code and configuration hashes must each contain 64 hexadecimal digits.);
    %let cohort_mode=%lowcase(%superq(cohort_mode));
    %if &cohort_mode ne synthetic and &cohort_mode ne development_sample and &cohort_mode ne full_cohort %then
        %rbc_fit_fail(Cohort mode must be synthetic development_sample or full_cohort.);
    %if &preflight_only ne 0 and &preflight_only ne 1 %then %rbc_fit_fail(Invalid preflight-only mode.);
    %if &preflight_only=1 and &cohort_mode ne synthetic %then %rbc_fit_fail(Preflight-only mode is restricted to synthetic fixtures.);
    %if %length(%superq(fit_id))>119 %then %rbc_fit_fail(Fit identity cannot represent its full pairwise family identifier.);
    %let subject_key_source=PersonKey;
    %if &cohort_mode=synthetic %then %let subject_key_source=SYNTHETIC_PERSON;
    %let adjust=%upcase(&adjustment);
    %let factor_none=0;
    %if %upcase(&factor)=NONE %then %let factor_none=1;
    %let before_time=-60;
    %let after_time=60;

    %if %length(%superq(job_id))=0 or %length(%superq(job_id))>12 %then
        %rbc_fit_fail(job_id must have 1 to 12 V7 characters.);
    %if %sysfunc(nvalid(%superq(job_id),V7)) ne 1 %then
        %rbc_fit_fail(job_id is not a V7 name.);
    %if %sysfunc(libref(&outlib)) ne 0 %then
        %rbc_fit_fail(OUTLIB is not assigned.);
    %if &adjust ne BASE and &adjust ne FULL %then
        %rbc_fit_fail(adjustment must be BASE or FULL.);
    %if &factor_none=0 %then %do;
        %if %sysfunc(nvalid(%superq(factor),V7)) ne 1 %then
            %rbc_fit_fail(factor must be one V7 name.);
    %end;
     
    %let planned_codes=;
    %if &factor_none=1 %then %let planned_codes=1;
    %else %if %upcase(&factor)=DONORHB_CAT or %upcase(&factor)=STORAGE_CAT %then %let planned_codes=1 2 3 4 5;
    %else %if %upcase(&factor)=DONORSEX %then %let planned_codes=1 2;
    %else %if %upcase(&factor)=DONORPARITY_FEMALE %then %let planned_codes=0 1;
    %else %if %upcase(&factor)=WDY_DONATION %then %let planned_codes=1 2 3 4 5 6 7;
    %else %rbc_fit_fail(Unrecognised planned factor.);
    %let planned_k=%sysfunc(countw(&planned_codes));
     
    %if %upcase(%superq(vital)) ne ARTM and %upcase(%superq(vital)) ne ARTS and
        %upcase(%superq(vital)) ne ARTD and %upcase(%superq(vital)) ne HR and
        %upcase(%superq(vital)) ne FIO2 and %upcase(%superq(vital)) ne SPO2 and
        %upcase(%superq(vital)) ne VE %then
        %rbc_fit_fail(Unrecognised canonical vital code.);
    %if &keep_scratch ne 0 and &keep_scratch ne 1 %then
        %rbc_fit_fail(keep_scratch must be 0 or 1.);

    %let scratch_members=%sysfunc(compbl(%rbc_fit_scratch_names));

    %let existing=0;
    %do i=1 %to %sysfunc(countw(&scratch_members));
        %let member=%scan(&scratch_members,&i);
        %if %sysfunc(exist(work.&member,DATA)) or
            %sysfunc(exist(work.&member,VIEW)) %then %let existing=%eval(&existing+1);
    %end;
    %rbc_fit_check_sas(stage=CHECK_02);
    %if &existing ne 0 %then
        %rbc_fit_fail(Reserved WORK scratch tables or views already exist. Use a fresh session or explicit reviewed cleanup.);

    proc sql noprint;
        select count(*) into :existing trimmed from dictionary.tables
        where libname=upcase("&outlib")
          and substr(memname,1,length("&job_id._"))=upcase("&job_id._");
    quit;
    %if &existing ne 0 %then %rbc_fit_fail(Job outputs already exist.);
    filename rbcest "%sysfunc(pathname(&outlib))/&job_id._estimates.sas";
    %if %sysfunc(fexist(rbcest)) %then
        %rbc_fit_fail(Generated contrast-code archive already exists.);

    data &outlib..&job_id._identity;
        length RunId $32 AnalysisSpecId PopulationId FitId InputSnapshotId DesignId ProfileId $128
            CodeHash ConfigHash $64 CohortMode $32 DFMethod $16 JobID $12
            SubjectKeySource SubjectAlias $16 DesignIdentityKind ProfileIdentityKind $32
            InferenceStatus $32;
        RunId="&run_id"; AnalysisSpecId="&analysis_spec_id";
        CohortMode="&cohort_mode"; PopulationId="&population_id"; FitId="&fit_id";
        InputSnapshotId="&input_snapshot_id"; CodeHash="&code_hash"; ConfigHash="&config_hash";
        DesignId="&design_id"; ProfileId="&profile_id"; DFMethod='RESIDUAL'; JobID="&job_id";
        SubjectKeySource="&subject_key_source"; SubjectAlias='PatientID';

        DesignIdentityKind='ASSIGNED_ID_NOT_CONTENT_HASH';
        ProfileIdentityKind='ASSIGNED_ID_NOT_CONTENT_HASH';
        InferenceStatus='MODEL_BASED_CANDIDATE'; BindingVersion=1;
    run;
    %let required_num=PatientID Value TimeFromTransfusion PatientAge RBC_Count ICU_time;
    %if &cohort_mode ne synthetic %then %rbc_fit_require(data=&data,variables=PersonKey,kind=N);
    %if &adjust=FULL %then
        %let required_num=&required_num Crystalloid_1 Crystalloid_24 Pressors_1 Pressors_24 Sedatives_1_bin Sedatives_24_bin;
    %if &factor_none=0 %then %let required_num=&required_num &factor;
    %if %upcase(&factor)=DONORPARITY_FEMALE %then
        %let required_num=&required_num DonorSex;
    %rbc_fit_require(data=&data,variables=&required_num,kind=N);
    %rbc_fit_require(data=&data,variables=RBC_EventKey VitalCode PatientSex WardName,kind=C);

    %let admission_handle=%sysfunc(open(&data,i));
    %if &admission_handle=0 %then %rbc_fit_fail(Required input table cannot be opened.);
    %let admission_pos=%sysfunc(varnum(&admission_handle,ICUAdmissionKey));
    %let admission_available=0;
    %if &admission_pos>0 %then %let admission_available=1;
    %let i=%sysfunc(close(&admission_handle));
    %if &admission_available=1 or &cohort_mode ne synthetic %then
        %rbc_fit_require(data=&data,variables=ICUAdmissionKey,kind=C);
    %let admission_status=NOT_PROVIDED_SYNTHETIC;
    %if &admission_available=1 %then %let admission_status=COMPUTED;

    proc contents data=&data out=work._rbc_inputcols(keep=name) noprint;
    run;
    proc sql noprint;
        select count(*) into :bad trimmed from work._rbc_inputcols
        where prxmatch('/^RBCX[0-9]+$/i',strip(name))>0
           or upcase(name) in ('GRIDID','CATEGORYINDEX','CATEGORYCODE',
               'RBC_DESIGNROW','RBC_SOURCE','RBC_CATEGORY',
               'PREDICTED','STDERR','LOWER','UPPER','_RBC_INPUT_VITALCODE');
    quit;
    %if &bad ne 0 %then %rbc_fit_fail(Input contains reserved model-engine fields.);

    data work._rbc_scope;

        length VitalCode $16;
        set &data(rename=(VitalCode=_RBC_INPUT_VITALCODE));
        where upcase(_RBC_INPUT_VITALCODE)=upcase("&vital");
        VitalCode="&vital";
        drop _RBC_INPUT_VITALCODE;
        %if &admission_available=1 %then %do;
            if missing(ICUAdmissionKey) then do;
                put 'ERROR: RBC_FIT_GUARD: Verified admission key is missing.';
                abort cancel;
            end;
        %end;
        %if &cohort_mode ne synthetic %then %do;
            if missing(PersonKey) or missing(PatientID) or PatientID ne PersonKey then do;
                put 'ERROR: RBC_FIT_GUARD: Model PatientID must be the explicit PersonKey alias.';
                abort cancel;
            end;
        %end;
        if missing(TimeFromTransfusion) then delete;
        if TimeFromTransfusion < -720 or TimeFromTransfusion > 720 then delete;
        %if &factor_none=1 %then %do; RBC_Category=1; %end;
        %else %do;
            if not missing(&factor) and &factor not in (&planned_codes) then do;
                put 'ERROR: RBC_FIT_GUARD: Unknown nonmissing planned category code.';
                abort cancel;
            end;
            RBC_Category=&factor;
        %end;
         
        %if %upcase(&factor)=DONORPARITY_FEMALE %then %do;
            if DonorSex ne 2 then delete;
            if DonorParity_Female not in (0,1) then delete;
        %end;
    run;
    %rbc_fit_check_sas(stage=CHECK_03);

    data work._rbc_real;
        length RBC_Source $5;
        set work._rbc_scope;
        if nmiss(of &required_num)>0 then delete;
        if missing(RBC_EventKey) or missing(PatientSex) or missing(WardName) then delete;

        RBC_Source='REAL';
        %if &factor_none=1 %then %do; RBC_Category=1; %end;
        %else %do; RBC_Category=&factor; %end;
    run;
    proc sql noprint;
        select count(*) into :n_input trimmed from &data;
        select count(*) into :n_scope trimmed from work._rbc_scope;
        select count(*), count(distinct PatientID), count(distinct RBC_EventKey),
               coalesce(sum(PatientSex='M'),0), coalesce(sum(PatientID=&score_subject),0)
        into :n_used trimmed,:n_patients trimmed,:n_events trimmed,
             :reference_sex_count trimmed,:sentinel_count trimmed
        from work._rbc_real;
        %if &admission_available=1 %then %do;
            select count(distinct ICUAdmissionKey) into :n_admissions trimmed
                from work._rbc_real;
            select count(*) into :bad trimmed from
                (select RBC_EventKey from work._rbc_real group by RBC_EventKey
                 having count(distinct ICUAdmissionKey) ne 1 or count(distinct PatientID) ne 1);
            %if &bad ne 0 %then %rbc_fit_fail(Event admission/person mapping is not unique in estimation rows.);
            select count(*) into :bad trimmed from
                (select ICUAdmissionKey from work._rbc_real group by ICUAdmissionKey
                 having count(distinct PatientID) ne 1);
            %if &bad ne 0 %then %rbc_fit_fail(Admission maps to multiple persons in estimation rows.);
        %end;
        %else %let n_admissions=.;
    quit;
    %rbc_fit_check_sas(stage=CHECK_04);
    %if &sentinel_count ne 0 %then
        %rbc_fit_fail(Scoring-only subject collides with a real subject.);

    proc sql;
        create table work._rbc_categories as
        select RBC_Category as CategoryCode, count(*) as N_Observations,
               count(distinct PatientID) as N_Patients,
               count(distinct RBC_EventKey) as N_Events
        from work._rbc_real group by RBC_Category order by RBC_Category;
    quit;
    data &outlib..&job_id._categories;
        set work._rbc_categories;
        CategoryIndex=_n_;
    run;
    proc sql noprint;
        select count(*) into :n_categories trimmed from &outlib..&job_id._categories;
    quit;

    data work._rbc_plannedcat;
        do _RBC_Level=1 to &planned_k;
            CategoryCode=input(scan("&planned_codes",_RBC_Level,' '),best32.); output;
        end;
        keep CategoryCode;
    run;
    proc sql;
        create table work._rbc_scopecat as select RBC_Category as CategoryCode,
            count(*) as N_Scope from work._rbc_scope
            where not missing(RBC_Category) group by RBC_Category;
        create table &outlib..&job_id._cat_availability as
        select p.CategoryCode,c.CategoryIndex,coalesce(s.N_Scope,0) as N_Scope,
            coalesce(c.N_Observations,0) as N_Observations,
            coalesce(c.N_Patients,0) as N_Patients,coalesce(c.N_Events,0) as N_Events,
            (coalesce(c.N_Observations,0)>0) as Available,
            case when c.N_Observations>0 then 'AVAILABLE'
                 when s.N_Scope>0 then 'LOST_AT_COMPLETE_CASE'
                 else 'ABSENT_IN_SCOPE' end as AvailabilityReason length=32
        from work._rbc_plannedcat p
        left join work._rbc_scopecat s on p.CategoryCode=s.CategoryCode
        left join &outlib..&job_id._categories c on p.CategoryCode=c.CategoryCode
        order by p.CategoryCode;
    quit;
    data &outlib..&job_id._family_plan;
        length FamilyID $128 FamilyRole $16 FactorName $32 Model $4 VitalCode $16
            PAdjustment CIAdjustment $32 FreezeStage $16;
        FamilyID="&fit_id..PAIRWISE"; FamilyRole='SECONDARY';

        if "&population_id"='PRIMARY' and "&adjust"='FULL' then FamilyRole='PRIMARY';
        FactorName="&factor"; Model="&adjust"; VitalCode="&vital";
        PlannedCategories=&planned_k; AvailableCategories=&n_categories;
        PlannedPairs=&planned_k*(&planned_k-1)/2; ActivePairs=&n_categories*(&n_categories-1)/2;
        PAdjustment='Holm within family'; CIAdjustment='None: pointwise';
        FreezeStage='PRE_FIT'; PlanVersion=1;
    run;
    proc sql;
        create table &outlib..&job_id._contrast_plan as
        select cats('W_',a.CategoryCode) as ContrastID length=32,
            'WITHIN' as ContrastType length=8,a.CategoryCode as CategoryCodeA,
            . as CategoryCodeB,a.CategoryIndex as CategoryIndexA,. as CategoryIndexB,
            1 as Planned,a.Available as Active,
            case when a.Available then 'NONE' else 'CATEGORY_UNAVAILABLE' end as ExclusionReason length=48,
            'NONE' as FamilyID length=128,-60 as BeforeMinute,60 as AfterMinute
        from &outlib..&job_id._cat_availability a
        union all
        select cats('P_',a.CategoryCode,'_',b.CategoryCode),'PAIRWISE',
            a.CategoryCode,b.CategoryCode,a.CategoryIndex,b.CategoryIndex,1,
            (a.Available and b.Available),
            case when a.Available and b.Available then 'NONE' else 'CATEGORY_UNAVAILABLE' end,
            "&fit_id..PAIRWISE",-60,60
        from &outlib..&job_id._cat_availability a inner join &outlib..&job_id._cat_availability b
            on a.CategoryCode<b.CategoryCode;
    quit;
    %let unavailable_reason=NONE;
    %if &n_input=0 %then %let unavailable_reason=EMPTY_MODEL_INPUT;
    %else %if &n_scope=0 %then %let unavailable_reason=NO_OUTCOME_WINDOW_ROWS;
    %else %if &n_used=0 %then %let unavailable_reason=NO_COMPLETE_MODEL_ROWS;
    %else %if &n_used<2 %then %let unavailable_reason=INSUFFICIENT_COMPLETE_ROWS;
    %else %if &n_patients<2 %then %let unavailable_reason=INSUFFICIENT_PERSONS;
    %else %if &reference_sex_count=0 %then %let unavailable_reason=DECLARED_REFERENCE_LEVEL_ABSENT;
    %else %if &factor_none=0 and &n_categories<2 %then %let unavailable_reason=FACTOR_AVAILABLE_CATEGORIES_LT2;
    data &outlib..&job_id._job_status;
        length JobStatus $32 ReasonCode $48 AdmissionCountStatus $32;
        JobStatus='READY_TO_FIT'; ReasonCode="&unavailable_reason"; FitAttempted=0;
        if ReasonCode ne 'NONE' then JobStatus='EXPECTED_UNAVAILABLE';
        N_Input=&n_input; N_Scope=&n_scope; N_Used=&n_used; N_Patients=&n_patients;
        N_Events=&n_events; N_Admissions=&n_admissions; AdmissionCountStatus="&admission_status";
        ReferenceCount=&reference_sex_count;
        AvailableCategories=&n_categories; PlanVersion=1;
    run;
    %rbc_fit_check_sas(stage=PREFIT_MANIFEST);
    %if &unavailable_reason ne NONE %then %do;
        %rbc_fit_bind_outputs(outlib=&outlib,job_id=&job_id);
        %if &keep_scratch=0 %then %rbc_fit_clear_scratch;
        %rbc_fit_check_sas(stage=EXPECTED_UNAVAILABLE);
        %let RBC_FIT_STATUS=EXPECTED_UNAVAILABLE;
        %let RBC_FIT_REASON=&unavailable_reason;
        %put NOTE: RBC_FIT_EXPECTED_UNAVAILABLE &unavailable_reason;
        %return;
    %end;
    %if &preflight_only=1 %then %do;
        %rbc_fit_bind_outputs(outlib=&outlib,job_id=&job_id);
        %if &keep_scratch=0 %then %rbc_fit_clear_scratch;
        %rbc_fit_check_sas(stage=SYNTHETIC_PREFLIGHT_ONLY);
        %let RBC_FIT_STATUS=READY_TO_FIT; %let RBC_FIT_REASON=NONE;
        %return;
    %end;
    %let n_score=%eval(1441*&n_categories);
    %let n_anchors=%eval(9*&n_categories);
    %let n_pairs=%eval(&n_categories*(&n_categories-1)/2);
    %let n_estimates=%eval(&n_anchors+&n_anchors*(&n_anchors-1)/2+&n_categories+&n_pairs);

    %rbc_fit_freeze_knots(outlib=&outlib,job_id=&job_id,adjustment=&adjust);

    proc means data=work._rbc_real noprint;
        var PatientAge ICU_time RBC_Count
            %if &adjust=FULL %then %do;
                Crystalloid_1 Crystalloid_24 Pressors_1 Pressors_24
                Sedatives_1_bin Sedatives_24_bin
            %end;
        ;
        output out=work._rbc_means(drop=_type_ _freq_) mean=;
    run;
    proc freq data=work._rbc_real order=freq noprint;
        tables WardName / out=work._rbc_ward;
    run;
    data &outlib..&job_id._profile;
        length PatientSex $1;
        if _n_=1 then set work._rbc_ward(obs=1 keep=WardName);
        set work._rbc_means;
        PatientSex='M';
    run;
    data work._rbc_score;
        length RBC_Source $5 RBC_EventKey $80 VitalCode $16;
        if _n_=1 then set &outlib..&job_id._profile;
        set &outlib..&job_id._categories(keep=CategoryIndex CategoryCode);
        RBC_Source='SCORE'; RBC_EventKey='SCORING_ONLY'; VitalCode="&vital";
        PatientID=&score_subject; Value=.; RBC_Category=CategoryCode;
        %if &factor_none=0 %then %do; &factor=CategoryCode; %end;
        do TimeFromTransfusion=-720 to 720;
            GridID=(CategoryIndex-1)*1441+TimeFromTransfusion+721;
            output;
        end;
    run;
    data work._rbc_both;
        set work._rbc_real work._rbc_score;
         
        RBC_DesignRow=_n_;
    run;
    %rbc_fit_check_sas(stage=CHECK_05);

    ods exclude all;
    proc glimmix data=work._rbc_both nofit
        outdesign(x=RBCX names)=work._rbc_design;
        class PatientSex WardName %if &factor_none=0 %then &factor; ;
        %rbc_native_effects(adjustment=&adjust,knots=&outlib..&job_id._knots);
        model Value=%rbc_native_terms(factor=&factor,adjustment=&adjust)
            / dist=normal link=identity;
    run;
    ods exclude none;
    %rbc_fit_check_sas(stage=CHECK_06);
    %if not %sysfunc(exist(work._rbc_design)) %then
        %rbc_fit_fail(GLIMMIX NOFIT did not create its design matrix.);

    proc contents data=work._rbc_design
        out=work._rbc_columns(keep=name label varnum type) noprint;
    run;
    proc sql;
        create table &outlib..&job_id._columns as
        select name as ColumnName length=32,label as ParameterLabel length=256,
               varnum as InputPosition,type as VariableType,
               input(substr(name,5),best32.) as ColumnIndex
        from work._rbc_columns
        where prxmatch('/^RBCX[0-9]+$/i',strip(name))>0
        order by calculated ColumnIndex;
    quit;
    proc sql noprint;
        select count(*),count(distinct ColumnIndex),min(ColumnIndex),max(ColumnIndex),
               sum(VariableType ne 1)
        into :n_columns trimmed,:coefficient_count trimmed,:i trimmed,:member trimmed,:bad trimmed
        from &outlib..&job_id._columns;
        select ColumnName into :xvars separated by ' '
        from &outlib..&job_id._columns order by ColumnIndex;
    quit;
    %if &n_columns=0 or &n_columns ne &coefficient_count or &i ne 1
        or &member ne &n_columns or &bad ne 0 %then
        %rbc_fit_fail(Design columns are not a contiguous numeric RBCX1..p mapping.);

    data &outlib..&job_id._column_scale;
        array X{&n_columns} &xvars;
        array Scale{&n_columns} _temporary_;
        do until(Last);
            set work._rbc_design(where=(RBC_Source='REAL')) end=Last;
            do j=1 to dim(X); Scale{j}=max(Scale{j},abs(X{j})); end;
        end;
        do j=1 to dim(X); X{j}=max(1,Scale{j}); end;
        keep &xvars;
        format &xvars best32.;
    run;
    data work._rbc_design;
        array X{&n_columns} &xvars;
        array Scale{&n_columns} _temporary_;
        if _n_=1 then do;
            set &outlib..&job_id._column_scale;
            do j=1 to dim(X); Scale{j}=X{j}; end;
        end;
        set work._rbc_design;
        do j=1 to dim(X); X{j}=X{j}/Scale{j}; end;
        drop j;
    run;
    data _null_;
        set work._rbc_design;
        if nmiss(of &xvars)>0 then do;
            put 'ERROR: RBC_FIT_GUARD: incomplete design row; no silent row loss allowed.';
            abort cancel;
        end;
    run;
    proc sql noprint;
        select count(*),sum(RBC_Source='SCORE') into :n_rows trimmed,:score_count trimmed
        from work._rbc_design;
    quit;
    %if &n_rows ne %eval(&n_used+&n_score) or &score_count ne &n_score %then
        %rbc_fit_fail(Design builder did not retain every real and missing-response score row.);

    data &outlib..&job_id._score_design;
        set work._rbc_design;
        if RBC_Source='SCORE';
        keep GridID CategoryIndex CategoryCode TimeFromTransfusion &xvars;
    run;
     
    proc sql noprint;
        select count(*),count(distinct GridID),min(GridID),max(GridID),
            sum(nmiss(s.GridID,s.CategoryIndex,s.CategoryCode,s.TimeFromTransfusion)>0
                or s.GridID ne (s.CategoryIndex-1)*1441+s.TimeFromTransfusion+721
                or s.GridID ne int(s.GridID)
                or s.CategoryIndex ne int(s.CategoryIndex)
                or s.CategoryIndex<1 or s.CategoryIndex>&n_categories
                or s.TimeFromTransfusion ne int(s.TimeFromTransfusion)
                or s.TimeFromTransfusion < -720 or s.TimeFromTransfusion > 720
                or missing(c.CategoryIndex) or s.CategoryCode ne c.CategoryCode)
        into :n_rows trimmed,:n_distinct trimmed,:min_key trimmed,:max_key trimmed,:bad trimmed
        from &outlib..&job_id._score_design s
        left join &outlib..&job_id._categories c on s.CategoryIndex=c.CategoryIndex;
    quit;
    %rbc_fit_check_sas(stage=CHECK_07);
    %if &n_rows ne &n_score or &n_distinct ne &n_score or &min_key ne 1
        or &max_key ne &n_score or &bad ne 0 %then
        %rbc_fit_fail(Score design has duplicate missing or invalid category-time keys.);
    proc sort data=&outlib..&job_id._score_design;
        by CategoryIndex TimeFromTransfusion;
    run;
    data &outlib..&job_id._anchor_design;
        set &outlib..&job_id._score_design;
        if TimeFromTransfusion in (-720,-660,-360,-60,0,60,360,660,720);
        AnchorID+1;
    run;
    proc sql noprint;
        select count(*) into :bad trimmed from &outlib..&job_id._anchor_design;
    quit;
    %if &bad ne &n_anchors %then %rbc_fit_fail(Anchor design is incomplete.);

    data work._rbc_requests;
        length Label $20 RequestType $12;
        array X{&n_columns} &xvars;
        array AnchorX{&n_anchors,&n_columns} _temporary_;
        array Cat{&n_anchors} _temporary_;
        array AtTime{&n_anchors} _temporary_;
        array Before{&n_categories} _temporary_;
        array After{&n_categories} _temporary_;
        do a=1 to &n_anchors;
            set &outlib..&job_id._anchor_design point=a;
            Cat{a}=CategoryIndex; AtTime{a}=TimeFromTransfusion;
            do j=1 to &n_columns; AnchorX{a,j}=X{j}; end;
            if TimeFromTransfusion=&before_time then Before{CategoryIndex}=a;
            if TimeFromTransfusion=&after_time then After{CategoryIndex}=a;
        end;
        do a=1 to &n_anchors;
            Label=cats('A',put(a,z3.)); RequestType='ANCHOR';
            AnchorA=a; AnchorB=.; CategoryA=Cat{a}; CategoryB=.;
            do j=1 to &n_columns; X{j}=AnchorX{a,j}; end;
            output;
            do b=a+1 to &n_anchors;
                Label=cats('AD',put(a,z3.),'_',put(b,z3.)); RequestType='ANCHOR_DIFF';
                AnchorA=a; AnchorB=b; CategoryA=Cat{a}; CategoryB=Cat{b};
                do j=1 to &n_columns; X{j}=AnchorX{a,j}-AnchorX{b,j}; end;
                output;
            end;
        end;
        do c=1 to &n_categories;
            if missing(Before{c}) or missing(After{c}) then do;
                put 'ERROR: RBC_FIT_GUARD: endpoint anchors are missing.';
                abort cancel;
            end;
            Label=cats('W',put(c,z3.)); RequestType='WITHIN';
            AnchorA=After{c}; AnchorB=Before{c}; CategoryA=c; CategoryB=.;
            do j=1 to &n_columns; X{j}=AnchorX{After{c},j}-AnchorX{Before{c},j}; end;
            output;
            do d=c+1 to &n_categories;
                Label=cats('P',put(c,z3.),'_',put(d,z3.)); RequestType='PAIRWISE';
                AnchorA=.; AnchorB=.; CategoryA=c; CategoryB=d;
                do j=1 to &n_columns;
                    X{j}=AnchorX{After{c},j}-AnchorX{Before{c},j}
                        -AnchorX{After{d},j}+AnchorX{Before{d},j};
                end;
                output;
            end;
        end;
        stop;
        keep Label RequestType AnchorA AnchorB CategoryA CategoryB &xvars;
    run;
    data &outlib..&job_id._requests;
        set work._rbc_requests;
    run;
    data _null_;
        length CoefficientName $32;
        file rbcest lrecl=32767;
        set work._rbc_requests;
        array X{&n_columns} &xvars;
        if _n_=1 then do;
            put '/* RBC model archive context: assigned design/profile IDs, not content hashes.';
            put "RunId=&run_id AnalysisSpecId=&analysis_spec_id CohortMode=&cohort_mode";
            put "PopulationId=&population_id FitId=&fit_id JobID=&job_id";
            put "InputSnapshotId=&input_snapshot_id CodeHash=&code_hash";
            put "ConfigHash=&config_hash DesignId=&design_id ProfileId=&profile_id";
            put "DFMethod=RESIDUAL SubjectAlias=PatientID SubjectKeySource=&subject_key_source */";
        end;
        put "estimate '" Label +(-1) "'";
        do j=1 to &n_columns;
             
            CoefficientName=vname(X{j});
            put '    ' CoefficientName $32. ' ' X{j} best32.;
        end;
        put ' / cl alpha=0.05;';
    run;
    %if &n_categories>1 %then %do;
        data _null_;
            length CoefficientName $32;
            file rbcest mod lrecl=32767;
            set work._rbc_requests(where=(RequestType='PAIRWISE' and CategoryA=1)) end=last;
            array X{&n_columns} &xvars;
            if _n_=1 then put "contrast 'EndpointChange'";
            do j=1 to &n_columns;
                CoefficientName=vname(X{j});
            put '    ' CoefficientName $32. ' ' X{j} best32.;
            end;
            if not last then put ',';
            else put ' / e;';
        run;

        data &outlib..&job_id._interaction_design;
            array X{&n_columns} &xvars;
            array AnchorBasis{&n_anchors,&n_columns} _temporary_;
            do a=1 to &n_anchors;
                set &outlib..&job_id._anchor_design point=a;
                do j=1 to &n_columns; AnchorBasis{a,j}=X{j}; end;
            end;
            do CategoryIndex=2 to &n_categories;
                do KnotIndex=2 to 8;
                    if KnotIndex=5 then continue;
                    do j=1 to &n_columns;
                        X{j}=AnchorBasis{9*(CategoryIndex-1)+KnotIndex,j}
                            -AnchorBasis{9*(CategoryIndex-1)+5,j}-AnchorBasis{KnotIndex,j}+AnchorBasis{5,j};
                    end;
                    output;
                end;
            end;
            stop;
            keep CategoryIndex KnotIndex &xvars;
        run;
        data _null_;
            length CoefficientName $32;
            file rbcest mod lrecl=32767;
            set &outlib..&job_id._interaction_design end=last;
            array X{&n_columns} &xvars;
            if _n_=1 then put "contrast 'WholeTrajectoryInteraction'";
            do j=1 to &n_columns;
                CoefficientName=vname(X{j});
                put '    ' CoefficientName $32. ' ' X{j} best32.;
            end;
            if not last then put ','; else put ' / e;';
        run;
    %end;
    %rbc_fit_check_sas(stage=CHECK_08);

    %if &optimizer_restart=NEWRAP_ONCE %then %do;
        %rbc_fit_restart_path(outlib=&outlib,job_id=&job_id,xvars=&xvars,
            n_categories=&n_categories,run_id=&run_id);
    %end;
    %else %do;
    ods exclude all;
    ods output ParameterEstimates=&outlib..&job_id._solution
        CovParms=&outlib..&job_id._covparms
        ConvergenceStatus=&outlib..&job_id._convergence
        FitStatistics=&outlib..&job_id._fitstats
        NObs=&outlib..&job_id._nobs
        Estimates=&outlib..&job_id._estimates
        %if &n_categories>1 %then %do;
            Contrasts=&outlib..&job_id._omnibus_raw
            Coef=&outlib..&job_id._coef
        %end;
    ;
    proc hpmixed data=work._rbc_design method=reml noclprint;
        nloptions tech=newrap gconv=1e-10 absgconv=1e-8 fconv=0 absfconv=0 maxiter=200;
        class PatientID;
        model Value=&xvars / noint solution ddfm=residual;
        random intercept / subject=PatientID;
        %include rbcest;
        output out=work._rbc_predictions pred(noblup)=Predicted
            stderr(noblup)=StdErr lcl(noblup)=Lower ucl(noblup)=Upper;
    run;
    ods output close;
    ods exclude none;
    %end;
    filename rbcest clear;
    %rbc_fit_check_sas(stage=CHECK_09);

    %rbc_fit_check_nobs(data=&outlib..&job_id._nobs,
        schema=&outlib..&job_id._nobs_schema,
        expected_read=%eval(&n_used+&n_score),expected_used=&n_used);
    %rbc_fit_require(data=&outlib..&job_id._convergence,variables=Status,kind=N);
    proc sql noprint;
        select count(*),sum(Status ne 0) into :n_rows trimmed,:bad trimmed
        from &outlib..&job_id._convergence;
    quit;
    %if &n_rows ne 1 or &bad ne 0 %then %rbc_fit_fail(Model did not converge.);
     
    %let model_suffixes=solution fitstats;
    %do i=1 %to %sysfunc(countw(&model_suffixes,%str( )));
        %let member=%scan(&model_suffixes,&i,%str( ));
        %if not %sysfunc(exist(&outlib..&job_id._&member)) %then
            %rbc_fit_fail(Required model archive output &member is absent.);
        proc sql noprint;
            select count(*) into :n_rows trimmed from &outlib..&job_id._&member;
        quit;
        %if &n_rows=0 %then %rbc_fit_fail(Required model archive output &member is empty.);
    %end;
    %rbc_fit_require(data=&outlib..&job_id._covparms,variables=CovParm,kind=C);
    %rbc_fit_require(data=&outlib..&job_id._covparms,variables=Estimate,kind=N);
    proc sql noprint;
        select count(*),count(distinct CovParm),
            sum(missing(Estimate) or CovParm not in ('Intercept','Residual')
                or Estimate<0 or (CovParm='Residual' and Estimate<=0))
        into :n_rows trimmed,:n_distinct trimmed,:bad trimmed
        from &outlib..&job_id._covparms;
    quit;
    %rbc_fit_check_sas(stage=CHECK_10);
    %if &n_rows ne 2 or &n_distinct ne 2 or &bad ne 0 %then
        %rbc_fit_fail(Random-intercept covariance parameters are invalid or incomplete.);
    %rbc_fit_require(data=&outlib..&job_id._estimates,
        variables=Estimate StdErr DF Probt Lower Upper,kind=N);
    %rbc_fit_require(data=&outlib..&job_id._estimates,variables=Label,kind=C);
    proc sql noprint;
        select count(*),count(distinct Label),
            sum(nmiss(Estimate,StdErr,DF,Probt,Lower,Upper)>0 or StdErr<0
                or DF<=0 or Probt<0 or Probt>1 or Lower>Estimate or Estimate>Upper)
        into :n_rows trimmed,:coefficient_count trimmed,:bad trimmed
        from &outlib..&job_id._estimates;
    quit;
    %if &n_rows ne &n_estimates or &coefficient_count ne &n_estimates or &bad ne 0 %then
        %rbc_fit_fail(Missing duplicated or nonestimable requested model contrasts.);
    proc sql noprint;
        select count(*),count(distinct Label)
        into :n_rows trimmed,:n_distinct trimmed from work._rbc_requests;
        select count(*) into :bad trimmed
        from work._rbc_requests r full join &outlib..&job_id._estimates e
        on r.Label=e.Label where missing(r.Label) or missing(e.Label);
        select count(distinct DF),min(DF) into :coefficient_count trimmed,:residual_df trimmed
        from &outlib..&job_id._estimates;
    quit;
    %rbc_fit_check_sas(stage=CHECK_11);
    %if &n_rows ne &n_estimates or &n_distinct ne &n_estimates or &bad ne 0 %then
        %rbc_fit_fail(Request and estimate label sets do not match exactly.);
    %if &coefficient_count ne 1 %then
        %rbc_fit_fail(Residual degrees of freedom differ between same-fit estimates.);

    proc sql;
        create table work._rbc_results as
        select r.Label,r.RequestType,r.AnchorA,r.AnchorB,r.CategoryA,r.CategoryB,
               ca.CategoryCode as CategoryCodeA,cb.CategoryCode as CategoryCodeB,
               e.Estimate,e.StdErr,e.DF,e.Probt as PValue,e.Lower,e.Upper
        from work._rbc_requests r left join &outlib..&job_id._estimates e
        on r.Label=e.Label
        left join &outlib..&job_id._categories ca on r.CategoryA=ca.CategoryIndex
        left join &outlib..&job_id._categories cb on r.CategoryB=cb.CategoryIndex;
    quit;
    proc sql noprint;
        select count(*),sum(nmiss(Estimate,StdErr,DF,PValue,Lower,Upper,CategoryCodeA)>0
            or (not missing(CategoryB) and missing(CategoryCodeB)))
        into :n_rows trimmed,:bad trimmed from work._rbc_results;
    quit;
    %rbc_fit_check_sas(stage=CHECK_12);
    %if &n_rows ne &n_estimates or &bad ne 0 %then
        %rbc_fit_fail(Contrast joins lost estimates or category codes.);
    data &outlib..&job_id._within_changes &outlib..&job_id._pairwise_raw
         &outlib..&job_id._anchor_est;
        length JobID $12 VitalCode $16 FactorName $32 Model $4;
        set work._rbc_results;
        JobID="&job_id"; VitalCode="&vital"; FactorName="&factor"; Model="&adjust";
        BeforeMinute=&before_time; AfterMinute=&after_time;
        if RequestType='WITHIN' then output &outlib..&job_id._within_changes;
        else if RequestType='PAIRWISE' then output &outlib..&job_id._pairwise_raw;
        else output &outlib..&job_id._anchor_est;
    run;

    proc sort data=&outlib..&job_id._pairwise_raw out=work._rbc_holm;
        by PValue Label;
    run;
    data &outlib..&job_id._pairwise;
        length PAdjustment $20 CIAdjustment $20;
        set work._rbc_holm;
        retain PreviousHolm 0;
        FamilySize=&n_pairs;
        Rank=_n_;
        PValue_Holm=min(1,max(PreviousHolm,(&n_pairs-Rank+1)*PValue));
        PreviousHolm=PValue_Holm;
        PAdjustment='Holm within family'; CIAdjustment='None: pointwise';
        drop PreviousHolm;
    run;
    %if &n_categories>1 %then %do;
        %rbc_fit_require(data=&outlib..&job_id._omnibus_raw,
            variables=NumDF DenDF FValue ProbF,kind=N);
        data &outlib..&job_id._omnibus;
            length JobID $12 VitalCode $16 FactorName $32 Model $4 Estimand $80;
            set &outlib..&job_id._omnibus_raw;
            if Label ne 'EndpointChange' then delete;
            if nmiss(NumDF,DenDF,FValue,ProbF)>0 or NumDF ne %eval(&n_categories-1)
                or DenDF ne &residual_df or FValue<0 or ProbF<0 or ProbF>1 then do;
                put 'ERROR: RBC_FIT_GUARD: invalid endpoint-change omnibus test.';
                abort cancel;
            end;
            JobID="&job_id"; VitalCode="&vital"; FactorName="&factor"; Model="&adjust";
            Estimand='Equality of +60 minus -60 minute changes across categories';
        run;
        proc sql noprint;
            select count(*) into :bad trimmed from &outlib..&job_id._omnibus;
        quit;
        %if &bad ne 1 %then %rbc_fit_fail(Endpoint-change omnibus output missing.);
        data &outlib..&job_id._interaction_test;
            length JobID $12 VitalCode $16 FactorName $32 Model $4 Estimand $80;
            set &outlib..&job_id._omnibus_raw;
            if Label ne 'WholeTrajectoryInteraction' then delete;
            if nmiss(NumDF,DenDF,FValue,ProbF)>0 or NumDF ne %eval(6*(&n_categories-1))
                or DenDF ne &residual_df or FValue<0 or ProbF<0 or ProbF>1 then do;
                put 'ERROR: RBC_FIT_GUARD: invalid whole-trajectory interaction test.';
                abort cancel;
            end;
            JobID="&job_id"; VitalCode="&vital"; FactorName="&factor"; Model="&adjust";
            Estimand='Equality of complete time-dependent changes across categories';
        run;
        proc sql noprint;
            select count(*) into :bad trimmed from &outlib..&job_id._interaction_test;
        quit;
        %if &bad ne 1 %then %rbc_fit_fail(Whole-trajectory interaction output missing.);
    %end;
    %else %do;
        data &outlib..&job_id._omnibus &outlib..&job_id._interaction_test;
            length JobID $12 VitalCode $16 FactorName $32 Model $4 Estimand $80
                Label $32 NumDF DenDF FValue ProbF 8;
            stop;
        run;
    %end;

    data work._rbc_curve;
        set work._rbc_predictions;
        if RBC_Source='SCORE';
        if nmiss(Predicted,StdErr,Lower,Upper)>0 or StdErr<0 or Lower>Predicted or Predicted>Upper then do;
            put 'ERROR: RBC_FIT_GUARD: missing or invalid prediction interval.';
            abort cancel;
        end;
        keep GridID CategoryIndex CategoryCode TimeFromTransfusion Predicted StdErr Lower Upper;
    run;
    proc sql noprint;
        select count(*),count(distinct GridID) into :n_rows trimmed,:n_distinct trimmed
        from work._rbc_curve;
        select count(*) into :bad trimmed
        from &outlib..&job_id._score_design s full join work._rbc_curve p
        on s.GridID=p.GridID
        where missing(s.GridID) or missing(p.GridID)
            or s.CategoryIndex ne p.CategoryIndex or s.CategoryCode ne p.CategoryCode
            or s.TimeFromTransfusion ne p.TimeFromTransfusion;
    quit;
    %rbc_fit_check_sas(stage=CHECK_13);
    %if &n_rows ne &n_score or &n_distinct ne &n_score or &bad ne 0 %then
        %rbc_fit_fail(Prediction grid keys do not match the score design.);
    proc sql;
        create table &outlib..&job_id._trajectory as
        select "&job_id" as JobID length=12,"&vital" as VitalCode length=16,
               "&factor" as FactorName length=32,"&adjust" as Model length=4,
               a.*,a.Predicted-b.Predicted as Delta,&before_time as BaselineMinute
        from work._rbc_curve a left join work._rbc_curve b
        on a.CategoryIndex=b.CategoryIndex and b.TimeFromTransfusion=&before_time
        order by a.CategoryIndex,a.TimeFromTransfusion;
        create table work._rbc_endpoint_check as
        select w.CategoryA,w.Estimate,w.StdErr,
               post.Predicted-pre.Predicted as CurveChange
        from &outlib..&job_id._within_changes w
        left join work._rbc_curve pre on w.CategoryA=pre.CategoryIndex
            and pre.TimeFromTransfusion=&before_time
        left join work._rbc_curve post on w.CategoryA=post.CategoryIndex
            and post.TimeFromTransfusion=&after_time;
    quit;
    proc sql noprint;
        select count(*) into :score_count trimmed from &outlib..&job_id._trajectory;
        select count(*),sum(missing(CurveChange) or abs(Estimate-CurveChange)>1e-7*max(1,abs(CurveChange)))
        into :n_rows trimmed,:bad trimmed from work._rbc_endpoint_check;
    quit;
    %if &score_count ne &n_score or &n_rows ne &n_categories or &bad ne 0 %then
        %rbc_fit_fail(Endpoint changes do not reproduce fitted trajectory differences.);

    data &outlib..&job_id._anchor_levels;
        set &outlib..&job_id._anchor_est;
        if RequestType='ANCHOR';
        AnchorID=AnchorA;
        keep AnchorID Estimate StdErr DF Lower Upper;
    run;
    data &outlib..&job_id._anchor_diffs;
        set &outlib..&job_id._anchor_est;
        if RequestType='ANCHOR_DIFF';
        LeftAnchor=AnchorA; RightAnchor=AnchorB;
        keep LeftAnchor RightAnchor Estimate StdErr DF Lower Upper;
    run;

    proc sql;
        create table work._rbc_anchor_levels as
        select AnchorA as AnchorIndex,Estimate,StdErr,DF
        from &outlib..&job_id._anchor_est where RequestType='ANCHOR';
        create table work._rbc_cov_offdiag as
        select d.AnchorA as RowIndex,d.AnchorB as ColumnIndex,
               (a.StdErr*a.StdErr+b.StdErr*b.StdErr-d.StdErr*d.StdErr)/2 as Covariance
        from &outlib..&job_id._anchor_est d
        inner join work._rbc_anchor_levels a on d.AnchorA=a.AnchorIndex
        inner join work._rbc_anchor_levels b on d.AnchorB=b.AnchorIndex
        where d.RequestType='ANCHOR_DIFF';
    quit;
    data &outlib..&job_id._anchor_cov;
        length ValidationStatus $32;
        set work._rbc_anchor_levels(in=diagonal)
            work._rbc_cov_offdiag;
        ValidationStatus='PENDING_MATRIX_VALIDATION';
        if diagonal then do;
            RowIndex=AnchorIndex; ColumnIndex=AnchorIndex;
            Covariance=StdErr*StdErr; output;
        end;
        else do;
            output;
            Swap=RowIndex; RowIndex=ColumnIndex; ColumnIndex=Swap; output;
        end;
        keep RowIndex ColumnIndex Covariance ValidationStatus;
    run;
    proc sql noprint;
        select count(*),sum(missing(Covariance)) into :n_rows trimmed,:bad trimmed
        from &outlib..&job_id._anchor_cov;
    quit;
    %if &n_rows ne %eval(&n_anchors*&n_anchors) or &bad ne 0 %then
        %rbc_fit_fail(Anchor covariance archive is incomplete.);

    data &outlib..&job_id._fitmetadata;
        length JobID $12 VitalCode $16 FactorName $32 Model $4
               FitStatus $32 ArchiveStatus $32 DDFMethod $16 CovarianceModel $80
               Optimizer $12 ColumnScaleMethod KnotPolicy AdmissionCountStatus $32;
        JobID="&job_id"; VitalCode="&vital"; FactorName="&factor"; Model="&adjust";
        N_Scope=&n_scope; N_Used=&n_used; N_Excluded_Missing=&n_scope-&n_used;
        N_Patients=&n_patients; N_Events=&n_events; N_Categories=&n_categories;
        N_Admissions=&n_admissions; AdmissionCountStatus="&admission_status";
        N_DesignColumns=&n_columns; N_Anchors=&n_anchors; N_RequestedEstimates=&n_estimates;
        BeforeMinute=&before_time; AfterMinute=&after_time;
        DDFMethod='RESIDUAL'; ResidualDF=&residual_df;
        Optimizer='NEWRAP'; GConv=1e-10; AbsGConv=1e-8; MaxIter=200;
        ColumnScaleMethod='MAX_ABS_REAL_MIN1';
        KnotPolicy='REAL_COMPLETE_CASE_NATIVE_SAS';
        CovarianceModel='Patient random intercept; independent conditional residuals';
        FitStatus='FIT_CHECKS_PASSED';
        ArchiveStatus='PENDING_MATRIX_VALIDATION';
        EngineRunChecksPassed=1;
    run;
    %rbc_fit_check_sas(stage=CHECK_14);

    data &outlib..&job_id._job_status;
        set &outlib..&job_id._job_status;
        JobStatus='FIT_CHECKS_PASSED'; FitAttempted=1;
    run;
    %rbc_fit_bind_outputs(outlib=&outlib,job_id=&job_id);

    proc sql noprint;
        select memname into :model_suffixes separated by ' '
        from dictionary.tables
        where libname=upcase("&outlib") and memtype='DATA'
          and substr(memname,1,length("&job_id._"))=upcase("&job_id._");
    quit;
    proc datasets library=&outlib nolist;
        %do i=1 %to %sysfunc(countw(&model_suffixes,%str( )));
            modify %scan(&model_suffixes,&i,%str( ));
            format _numeric_ best32.;
        %end;
    quit;
    %rbc_fit_check_sas(stage=CHECK_15);

    %if &keep_scratch=0 %then %do;
        %rbc_fit_clear_scratch;
    %end;
    %let RBC_FIT_STATUS=FIT_CHECKS_PASSED; %let RBC_FIT_REASON=NONE;
%mend rbc_fit_job;

