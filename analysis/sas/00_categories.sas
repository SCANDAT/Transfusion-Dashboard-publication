/* Category definitions.
   Donor hemoglobin, storage duration, donor sex, recorded female-donor parity and donation weekday rules.
   This file defines macros; use run.py to execute the analysis steps.
*/
%macro rbc_derive_category_fields(
    hb=DonorHb,
    storage=Storage,
    sex=DonorSex,
    parity=DonorParity,
    hb_cat=DonorHb_Cat,
    storage_cat=Storage_Cat,
    parity_cat=DonorParity_Female
);
    %local _rbc_inputs _rbc_outputs _rbc_i _rbc_j _rbc_name _rbc_other;

    %if %length(%superq(hb))=0 %then %do;
        %put ERROR: RBC_CATEGORY_GUARD: hb requires one V7 variable name.;
        %abort cancel;
    %end;
    %if %sysfunc(nvalid(%superq(hb),V7)) ne 1 %then %do;
        %put ERROR: RBC_CATEGORY_GUARD: hb is not one V7 variable name.;
        %abort cancel;
    %end;
    %if %length(%superq(storage))=0 %then %do;
        %put ERROR: RBC_CATEGORY_GUARD: storage requires one V7 variable name.;
        %abort cancel;
    %end;
    %if %sysfunc(nvalid(%superq(storage),V7)) ne 1 %then %do;
        %put ERROR: RBC_CATEGORY_GUARD: storage is not one V7 variable name.;
        %abort cancel;
    %end;
    %if %length(%superq(sex))=0 %then %do;
        %put ERROR: RBC_CATEGORY_GUARD: sex requires one V7 variable name.;
        %abort cancel;
    %end;
    %if %sysfunc(nvalid(%superq(sex),V7)) ne 1 %then %do;
        %put ERROR: RBC_CATEGORY_GUARD: sex is not one V7 variable name.;
        %abort cancel;
    %end;
    %if %length(%superq(parity))=0 %then %do;
        %put ERROR: RBC_CATEGORY_GUARD: parity requires one V7 variable name.;
        %abort cancel;
    %end;
    %if %sysfunc(nvalid(%superq(parity),V7)) ne 1 %then %do;
        %put ERROR: RBC_CATEGORY_GUARD: parity is not one V7 variable name.;
        %abort cancel;
    %end;
    %if %length(%superq(hb_cat))=0 %then %do;
        %put ERROR: RBC_CATEGORY_GUARD: hb_cat requires one V7 variable name.;
        %abort cancel;
    %end;
    %if %sysfunc(nvalid(%superq(hb_cat),V7)) ne 1 %then %do;
        %put ERROR: RBC_CATEGORY_GUARD: hb_cat is not one V7 variable name.;
        %abort cancel;
    %end;
    %if %length(%superq(storage_cat))=0 %then %do;
        %put ERROR: RBC_CATEGORY_GUARD: storage_cat requires one V7 variable name.;
        %abort cancel;
    %end;
    %if %sysfunc(nvalid(%superq(storage_cat),V7)) ne 1 %then %do;
        %put ERROR: RBC_CATEGORY_GUARD: storage_cat is not one V7 variable name.;
        %abort cancel;
    %end;
    %if %length(%superq(parity_cat))=0 %then %do;
        %put ERROR: RBC_CATEGORY_GUARD: parity_cat requires one V7 variable name.;
        %abort cancel;
    %end;
    %if %sysfunc(nvalid(%superq(parity_cat),V7)) ne 1 %then %do;
        %put ERROR: RBC_CATEGORY_GUARD: parity_cat is not one V7 variable name.;
        %abort cancel;
    %end;

    %let _rbc_inputs=&hb &storage &sex &parity;
    %let _rbc_outputs=&hb_cat &storage_cat &parity_cat RBC_Parity_Female RBC_Hb_Status RBC_Storage_Status RBC_DonorSex_Status RBC_Parity_Status RBC_Hb_Label RBC_Storage_Label RBC_Parity_Label;
    %do _rbc_i=1 %to 11;
        %let _rbc_name=%upcase(%scan(&_rbc_outputs,&_rbc_i,%str( )));
        %if &_rbc_name=_N_ or &_rbc_name=_ERROR_ or &_rbc_name=_NUMERIC_
            or &_rbc_name=_CHARACTER_ or &_rbc_name=_ALL_ %then %do;
            %put ERROR: RBC_CATEGORY_GUARD: reserved output name.;
            %abort cancel;
        %end;
        %do _rbc_j=1 %to 4;
            %let _rbc_other=%upcase(%scan(&_rbc_inputs,&_rbc_j,%str( )));
            %if &_rbc_name=&_rbc_other %then %do;
                %put ERROR: RBC_CATEGORY_GUARD: output aliases an input variable.;
                %abort cancel;
            %end;
        %end;
        %do _rbc_j=1 %to %eval(&_rbc_i-1);
            %let _rbc_other=%upcase(%scan(&_rbc_outputs,&_rbc_j,%str( )));
            %if &_rbc_name=&_rbc_other %then %do;
                %put ERROR: RBC_CATEGORY_GUARD: duplicate output names.;
                %abort cancel;
            %end;
        %end;
    %end;

    if _n_=1 then do;
        if vtype(&hb) ne 'N' or vtype(&storage) ne 'N'
           or vtype(&sex) ne 'N' or vtype(&parity) ne 'N' then do;
            put 'ERROR: RBC_CATEGORY_GUARD: all four input variables must be numeric.';
            abort cancel;
        end;
    end;

    length &hb_cat &storage_cat &parity_cat 8
           RBC_Parity_Female 8
           RBC_Hb_Status RBC_Storage_Status RBC_DonorSex_Status $8
           RBC_Parity_Status $16
           RBC_Hb_Label RBC_Storage_Label $12
           RBC_Parity_Label $32;

    &hb_cat = .;
    &storage_cat = .;
    &parity_cat = .;
    RBC_Parity_Female = 0;
    RBC_Hb_Status = 'missing';
    RBC_Storage_Status = 'missing';
    RBC_DonorSex_Status = 'missing';
    RBC_Parity_Status = 'sex_missing';
    RBC_Hb_Label = 'Unknown';
    RBC_Storage_Label = 'Unknown';
    RBC_Parity_Label = 'Not eligible: donor sex missing';

    if not missing(&hb) then do;
        RBC_Hb_Status = 'observed';
        if &hb < 125 then do;
            &hb_cat = 1; RBC_Hb_Label = '<125';
        end;
        else if &hb < 140 then do;
            &hb_cat = 2; RBC_Hb_Label = '125-<140';
        end;
        else if &hb < 155 then do;
            &hb_cat = 3; RBC_Hb_Label = '140-<155';
        end;
        else if &hb < 170 then do;
            &hb_cat = 4; RBC_Hb_Label = '155-<170';
        end;
        else do;
            &hb_cat = 5; RBC_Hb_Label = '>=170';
        end;
    end;

    if not missing(&storage) then do;
        if &storage < 0 then do;
            RBC_Storage_Status = 'negative';
            RBC_Storage_Label = 'Invalid';
        end;
        else do;
            RBC_Storage_Status = 'valid';
            if &storage < 10 then do;
                &storage_cat = 1; RBC_Storage_Label = '0-<10';
            end;
            else if &storage < 20 then do;
                &storage_cat = 2; RBC_Storage_Label = '10-<20';
            end;
            else if &storage < 30 then do;
                &storage_cat = 3; RBC_Storage_Label = '20-<30';
            end;
            else if &storage < 40 then do;
                &storage_cat = 4; RBC_Storage_Label = '30-<40';
            end;
            else do;
                &storage_cat = 5; RBC_Storage_Label = '>=40';
            end;
        end;
    end;

    if not missing(&sex) then do;
        if &sex = 1 then do;
            RBC_DonorSex_Status = 'male';
            RBC_Parity_Status = 'not_female';
            RBC_Parity_Label = 'Not eligible: male donor';
        end;
        else if &sex = 2 then do;
            RBC_DonorSex_Status = 'female';
            RBC_Parity_Female = 1;
            if missing(&parity) then do;
                RBC_Parity_Status = 'parity_missing';
                RBC_Parity_Label = 'Unknown';
            end;
            else if &parity in (0, 1) then do;
                &parity_cat = &parity;
                RBC_Parity_Status = 'eligible';
                if &parity = 0 then RBC_Parity_Label = 'Parity 0';
                else RBC_Parity_Label = 'Parity 1';
            end;
            else do;
                RBC_Parity_Status = 'parity_invalid';
                RBC_Parity_Label = 'Invalid';
            end;
        end;
        else do;
            RBC_DonorSex_Status = 'invalid';
            RBC_Parity_Status = 'sex_invalid';
            RBC_Parity_Label = 'Not eligible: donor sex invalid';
        end;
    end;
%mend rbc_derive_category_fields;

%macro rbc_category_status_audit(data=, out=work.rbc_category_audit);
    proc sql;
        create table &out as
        select count(*) as N_Input_Rows,
            coalesce(sum(RBC_Hb_Status='missing'),0) as N_Hb_Missing,
            coalesce(sum(RBC_Hb_Status='observed'),0) as N_Hb_Observed,
            coalesce(sum(RBC_Storage_Status='missing'),0) as N_Storage_Missing,
            coalesce(sum(RBC_Storage_Status='negative'),0) as N_Storage_Negative,
            coalesce(sum(RBC_Storage_Status='valid'),0) as N_Storage_Valid,
            coalesce(sum(RBC_DonorSex_Status='missing'),0) as N_DonorSex_Missing,
            coalesce(sum(RBC_DonorSex_Status='invalid'),0) as N_DonorSex_Invalid,
            coalesce(sum(RBC_DonorSex_Status='male'),0) as N_DonorSex_Male,
            coalesce(sum(RBC_DonorSex_Status='female'),0) as N_DonorSex_Female,
            coalesce(sum(RBC_Parity_Status='eligible'),0) as N_Parity_Female_Valid,
            coalesce(sum(RBC_Parity_Status='parity_missing'),0) as N_Parity_Female_Missing,
            coalesce(sum(RBC_Parity_Status='parity_invalid'),0) as N_Parity_Female_Invalid,
            coalesce(sum(RBC_Parity_Status='not_female'),0) as N_Parity_Nonfemale,
            coalesce(sum(RBC_Parity_Status='sex_missing'),0) as N_Parity_Sex_Missing,
            coalesce(sum(RBC_Parity_Status='sex_invalid'),0) as N_Parity_Sex_Invalid
        from &data;
    quit;
%mend rbc_category_status_audit;

