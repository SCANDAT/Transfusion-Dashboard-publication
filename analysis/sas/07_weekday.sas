/* Donation-day inference for Monday to Friday.
   Load only for the separate weekday stage. The original model definitions,
   rows, fitted rank and working covariance remain unchanged. The reported
   family contains five weekday changes, ten pairwise comparisons and two
   joint tests. Weekend observations remain in the fitted model.

   For saved QR factors, the residual check uses the sum of the whitened
   residual norm and the active fitted-value norm. When covariance is reused,
   weekday contrasts use the original fit's full target-span covariance.
   The coefficient-correction cases also export the geometry needed to verify
   their corrected means.
*/

%macro rbc_cr2_iml_modules;
start cr2Sym(a); return((a+a`)/2); finish;
start cr2Norm(a); return(sqrt(ssq(a))); finish;
start cr2PSD(a,w,u) global(cr2rc);
  if nrow(a)^=ncol(a) | countmiss(a)>0 then do; cr2rc='MATRIX_INPUT'; return; end;
  scale=max(abs(a));
  if scale=0 then do; w=j(nrow(a),1,0); u=i(nrow(a)); return; end;
  if max(abs(a-a`))>1e-10*scale then do; cr2rc='ASYMMETRIC_INPUT'; return; end;
  call eigen(w,u,cr2Sym(a));
  if min(w)<-1e-10*max(abs(w)) then do; cr2rc='NON_PSD_INPUT'; return; end;
  w=choose(w<0,0,w);
finish;
start cr2Power(a,power) global(cr2rc);
  run cr2PSD(a,w,u);
  if cr2rc^='PASS' then return(j(nrow(a),ncol(a),.));
  if max(w)<=0 | min(w)<=1e-12*max(w) then do;
    cr2rc='ILL_CONDITIONED_PD_MATRIX'; return(j(nrow(a),ncol(a),.));
  end;
  return(cr2Sym(u*diag(w##power)*u`));
finish;
start cr2OpNorm(a);
  call eigen(w,u,cr2Sym(a)); return(max(abs(w)));
finish;
start cr2Root(V,S,A,rootError,steps) global(cr2rc);
  Vih=cr2Power(V,-.5); if cr2rc^='PASS' then return;
  A=i(nrow(V)); steps=0; done=0;
  do iteration=1 to 40 while(done=0);
    residual=cr2Sym(V-A*S*A);
    rootError=cr2OpNorm(Vih*residual*Vih);
    if rootError<=1e-10 then done=1;
    else do;
      Ah=cr2Power(A,.5); if cr2rc^='PASS' then return;
      Aih=cr2Power(A,-.5); if cr2rc^='PASS' then return;
      T=cr2Sym(Ah*S*Ah); run cr2PSD(T,lam,U);
      if cr2rc^='PASS' then return;
      if min(lam)<=0 then do; cr2rc='LYAPUNOV_DERIVATIVE_NOT_PD'; return; end;
      rhs=U`*Aih*residual*Aih*U;
      den=repeat(lam,1,nrow(lam))+repeat(lam`,nrow(lam),1);
      delta=cr2Sym(Ah*U*(rhs/den)*U`*Ah); accepted=0;
      do backtrack=0 to 29 while(accepted=0);
        candidate=cr2Sym(A+delta*2##(-backtrack));
        call eigen(cw,cu,candidate);
        if min(cw)>0 then do;
          candidateError=cr2OpNorm(Vih*(V-candidate*S*candidate)*Vih);
          if candidateError<rootError then do; A=candidate; accepted=1; end;
        end;
      end;
      if accepted=0 then done=1;
      else steps=steps+1;
    end;
  end;
  rootError=cr2OpNorm(Vih*cr2Sym(V-A*S*A)*Vih);
  if rootError=. | rootError>2e-8 then cr2rc='BRL_REFERENCE_IDENTITY_FAILED';
finish;
start cr2Core(raw,cross,beta,contrasts,tau2,sigma2,alpha,
              cov,basis,B,archive,inference,diagnostics) global(cr2rc);
  cr2rc='PASS'; tiny=constant('SMALL'); rankTol=1e-10;
  m=nrow(cross); k=ncol(cross); p=k-1;
  if m<2 then do; cr2rc='TOO_FEW_CLUSTERS'; return; end;
  if p<1 | nrow(raw)^=m*k | ncol(raw)^=k | nrow(beta)^=p |
     ncol(beta)^=1 | ncol(contrasts)^=p | nrow(contrasts)<1 then do;
    cr2rc='MATRIX_DIMENSIONS'; return;
  end;
  if countmiss(raw)+countmiss(cross)+countmiss(beta)+countmiss(contrasts)>0 then do;
    cr2rc='MISSING_MATRIX_INPUT'; return;
  end;
  if countmiss(tau2||sigma2||alpha)>0 | tau2<0 | sigma2<=0 |
     alpha<=0 | alpha>=1 then do; cr2rc='WORKING_VARIANCES_OR_ALPHA'; return; end;
  allG=j(m*p,p,0); allScore=j(m,p,0); total=j(p,p,0);
  do person=1 to m;
    rawGram=raw[((person-1)*k+1):(person*k),]; resCross=cross[person,]`;
    run cr2PSD(rawGram,hw,hu); if cr2rc^='PASS' then return;
    n=rawGram[1,1]; sx=rawGram[2:k,1];
    if n<1 | n^=round(n) then do; cr2rc='INVALID_CLUSTER_SIZE'; return; end;
    centered=cr2Sym(rawGram[2:k,2:k]-sx*sx`/n);
    G=cr2Sym(centered/sigma2+sx*sx`/(n*(sigma2+n*tau2)));
    run cr2PSD(G,gw,gu); if cr2rc^='PASS' then return;
    score=(resCross[2:k]-sx*resCross[1]/n)/sigma2+sx*resCross[1]/(n*(sigma2+n*tau2));
    allG[((person-1)*p+1):(person*p),]=G;
    allScore[person,]=score`; total=total+G;
  end;
  run cr2PSD(total,tw,tu); if cr2rc^='PASS' then return;
  if max(tw)<=0 then do; cr2rc='ZERO_DESIGN_RANK'; return; end;
  keep=loc(tw>rankTol*max(tw)); basis=tu[,keep]; rank=ncol(basis);
  B=diag(1/tw[keep]); Bh=diag(1/sqrt(tw[keep]));
  transform=j(k,rank+1,0); transform[1,1]=1; transform[2:k,2:(rank+1)]=basis;
  sumScore=j(rank,1,0); scoreScale=0; maxLeverage=0;
  activeG=j(m*rank,rank,0); activeScore=j(m,rank,0);
  do person=1 to m;
    score=allScore[person,]`; sa=basis`*score;
    if cr2Norm(score-basis*sa)>2e-8*max(cr2Norm(score),tiny) then do;
      cr2rc='SCORE_OUTSIDE_DESIGN_SPACE'; return;
    end;
    G=cr2Sym(basis`*allG[((person-1)*p+1):(person*p),]*basis);
    run cr2PSD(Bh*G*Bh,lw,lu); if cr2rc^='PASS' then return;
    maxLeverage=max(maxLeverage,max(lw));
    if max(lw)>=1-1e-10 then do; cr2rc='SATURATED_OR_NEAR_SATURATED'; return; end;
    activeG[((person-1)*rank+1):(person*rank),]=G;
    activeScore[person,]=sa`; sumScore=sumScore+sa; scoreScale=scoreScale+cr2Norm(sa);
  end;
  if cr2Norm(sumScore)>2e-8*max(scoreScale,tiny) then do;
    cr2rc='SCORES_NOT_FROM_FITTED_GLS'; return;
  end;
  allD=j(m*rank,rank,0); meat=j(rank,rank,0); diagnostics=j(m,5,0);
  do person=1 to m;
    rawGram=cr2Sym(transform`*raw[((person-1)*k+1):(person*k),]*transform);
    resCross=transform`*cross[person,]`;
    run cr2PSD(rawGram,hw,hu); if cr2rc^='PASS' then return;
    keep=loc(hw>rankTol*max(hw)); w=hw[keep]; U=hu[,keep];
    if ncol(keep)=0 then do; cr2rc='ZERO_LOCAL_SPAN'; return; end;
    if cr2Norm(resCross-U*(U`*resCross))>2e-8*max(cr2Norm(resCross),tiny) then do;
      cr2rc='RESIDUAL_CROSS_OUTSIDE_LOCAL_SPAN'; return;
    end;
    Rall=diag(sqrt(w))*U`; q1=Rall[,1]; projectX=Rall[,2:(rank+1)];
    er=(U`*resCross)/sqrt(w); V=sigma2*i(nrow(w))+tau2*q1*q1`;
    weight=cr2Power(V,-1); if cr2rc^='PASS' then return;
    S=cr2Sym(V-projectX*B*projectX`);
    run cr2Root(V,S,A,rootError,steps); if cr2rc^='PASS' then return;
    unadjusted=projectX`*weight*er;
    if max(abs(unadjusted-activeScore[person,]`)-2e-8*abs(activeScore[person,]`))>1e-10 then do;
      cr2rc='PROJECTED_SCORE_MISMATCH'; return;
    end;
    adjusted=projectX`*weight*A*er; adjCross=projectX`*weight*A*projectX;
    allD[((person-1)*rank+1):(person*rank),]=adjCross; meat=meat+adjusted*adjusted`;
    diagnostics[person,]=person||nrow(w)||rootError||steps||maxLeverage;
  end;
  activeCov=cr2Sym(B*meat*B); cov=cr2Sym(basis*activeCov*basis`);
   
  archive=j(m*rank*rank,5,0); pos=0;
  do person=1 to m;
    G=activeG[((person-1)*rank+1):(person*rank),]; adjCross=allD[((person-1)*rank+1):(person*rank),];
    do rr=1 to rank; do cc=1 to rank;
      pos=pos+1; archive[pos,]=person||rr||cc||G[rr,cc]||adjCross[rr,cc];
    end; end;
  end;

  inference=j(nrow(contrasts),12,.);
  do ci=1 to nrow(contrasts);
    c=contrasts[ci,]`; ca=basis`*c; inference[ci,1:2]=ci||0;
    if cr2Norm(c)=0 then inference[ci,2]=2;
    else if cr2Norm(c-basis*ca)>2e-8*cr2Norm(c) then inference[ci,2]=1;
    else do;
      actualCa=ca; ca=ca/cr2Norm(ca); contrastBread=B*ca; target=ca`*contrastBread;
      accumulator=j(rank,rank,0); offdiag=0; diagonal=0; qsum=0; maxShare=0;
      do person=1 to m;
        G=activeG[((person-1)*rank+1):(person*rank),]; adjCross=allD[((person-1)*rank+1):(person*rank),];
        qi=(contrastBread`*G*contrastBread)/target;
        if qi < -1e-9 then do; cr2rc='NEGATIVE_REFERENCE_COMPONENT'; return; end;
        qi=max(qi,0); qsum=qsum+qi; maxShare=max(maxShare,qi); diagonal=diagonal+qi*qi;
        z=Bh*adjCross`*contrastBread/sqrt(target); crossTerm=z`*accumulator*z;
        if crossTerm < -1e-9 then do; cr2rc='NEGATIVE_REFERENCE_CROSS'; return; end;
        offdiag=offdiag+2*max(crossTerm,0); accumulator=accumulator+z*z`;
      end;
      if abs(qsum-1)>1.1e-8 then do; cr2rc='REFERENCE_COMPONENT_SUM'; return; end;
      denom=diagonal+offdiag;
      if denom<=0 | denom=. then do; cr2rc='INVALID_DF_DENOMINATOR'; return; end;
      df=1/denom;
      if df<1-1e-8 | df>m*(1+1e-8) then do; cr2rc='DF_REFERENCE_BOUNDS'; return; end;
      variance=actualCa`*activeCov*actualCa;
      if variance<=0 then inference[ci,2]=3;
      else do;
        estimate=c`*beta; se=sqrt(variance); t=estimate/se;
        pvalue=2*cdf('T',-abs(t),df); critical=tinv(1-alpha/2,df);
        reference=actualCa`*B*actualCa;
        inference[ci,3:12]=estimate||se||df||t||pvalue||(estimate-critical*se)||
          (estimate+critical*se)||variance||reference||maxShare;
      end;
    end;
  end;
finish;
%mend;

%macro rbc_person_cluster_inference(gram=,cross=,solution=,contrasts=,context=,
                                   outlib=WORK,prefix=cr2);
%local _j _member _members;
%let _members=covariance basis bread archive inference diagnostics solution context status;
%if not %sysfunc(nvalid(&prefix,V7)) or %length(&prefix)>16 or
    not %sysfunc(nvalid(&outlib,V7)) %then %abort cancel;
%do _j=1 %to %sysfunc(countw(&_members));
  %let _member=%scan(&_members,&_j);
  %if %sysfunc(exist(&outlib..&prefix._&_member)) %then %abort cancel;
%end;
proc iml;
  %rbc_cr2_iml_modules;
  cr2rc=repeat(' ',1,64); cr2rc='PASS';
  start cr2Interface(dummy) global(cr2rc,RunId,FitId,Scope);
    use &context; read all var {RunId FitId Scope};
      read all var {Tau2 Sigma2 Alpha} into working; close &context;
    if nrow(RunId)^=1 | nrow(FitId)^=1 | nrow(Scope)^=1 | nrow(working)^=1 then do;
      cr2rc='CONTEXT_CARDINALITY'; return;
    end;
    if Scope^='SYNTHETIC_DATA_ONLY' | length(strip(RunId))^=32 |
       length(strip(FitId))<1 then do; cr2rc='CONTEXT_SCOPE'; return; end;
    use &solution; read all var {Parameter Estimate} into bl; close &solution;
    use &gram; read all var {Cluster Row Col Value} into gl; close &gram;
    use &cross; read all var {Cluster Row Value} into hl; close &cross;
    use &contrasts; read all var {Contrast Parameter Weight} into cl; close &contrasts;
    if countmiss(bl)+countmiss(gl)+countmiss(hl)+countmiss(cl)>0 then do;
      cr2rc='MISSING_INTERFACE_INPUT'; return;
    end;
    p=nrow(bl); k=p+1; m=max(gl[,1]); nc=max(cl[,1]);
    if p<1 | p>200 | m<2 | m>1000 | nc<1 | nc>2000 then do;
      cr2rc='SYNTHETIC_INTERFACE_SIZE'; return;
    end;
    if any(bl[,1]^=round(bl[,1])) | any(gl[,1:3]^=round(gl[,1:3])) |
       any(hl[,1:2]^=round(hl[,1:2])) | any(cl[,1:2]^=round(cl[,1:2])) then do;
      cr2rc='NONINTEGER_INTERFACE_INDEX'; return;
    end;
    if min(bl[,1])<1 | max(bl[,1])>p |
       min(gl[,1])<1 | min(gl[,2:3])<1 | max(gl[,2:3])>k |
       min(hl[,1])<1 | max(hl[,1])>m | min(hl[,2])<1 | max(hl[,2])>k |
       min(cl[,1])<1 | min(cl[,2])<1 | max(cl[,2])>p then do;
      cr2rc='INTERFACE_INDEX_BOUNDS'; return;
    end;
    if nrow(gl)^=m*k*k | nrow(hl)^=m*k | nrow(cl)^=nc*p then do;
      cr2rc='INTERFACE_CARDINALITY'; return;
    end;
    raw=j(m*k,k,.); cross=j(m,k,.); beta=j(p,1,.); contrasts=j(nc,p,.);
    do j=1 to nrow(bl);
      if beta[bl[j,1]]^=. then do; cr2rc='DUPLICATE_BETA_CELL'; return; end;
      beta[bl[j,1]]=bl[j,2];
    end;
    do j=1 to nrow(gl);
      rr=(gl[j,1]-1)*k+gl[j,2]; cc=gl[j,3];
      if raw[rr,cc]^=. then do; cr2rc='DUPLICATE_GRAM_CELL'; return; end;
      raw[rr,cc]=gl[j,4];
    end;
    do j=1 to nrow(hl);
      rr=hl[j,1]; cc=hl[j,2];
      if cross[rr,cc]^=. then do; cr2rc='DUPLICATE_CROSS_CELL'; return; end;
      cross[rr,cc]=hl[j,3];
    end;
    do j=1 to nrow(cl);
      rr=cl[j,1]; cc=cl[j,2];
      if contrasts[rr,cc]^=. then do; cr2rc='DUPLICATE_CONTRAST_CELL'; return; end;
      contrasts[rr,cc]=cl[j,3];
    end;
    run cr2Core(raw,cross,beta,contrasts,working[1,1],working[1,2],working[1,3],
                cov,basis,B,archive,inference,diagnostics);
    if cr2rc^='PASS' then return;
    r=ncol(basis); covLong=j(p*p,3,0); basisLong=j(p*r,3,0); breadLong=j(r*r,3,0);
    pos=0; do rr=1 to p; do cc=1 to p;
      pos=pos+1; covLong[pos,]=rr||cc||cov[rr,cc];
    end; end;
    pos=0; do rr=1 to p; do cc=1 to r;
      pos=pos+1; basisLong[pos,]=rr||cc||basis[rr,cc];
    end; end;
    pos=0; do rr=1 to r; do cc=1 to r;
      pos=pos+1; breadLong[pos,]=rr||cc||B[rr,cc];
    end; end;
    create &outlib..&prefix._covariance from covLong[colname={'Row' 'Col' 'Value'}];
      append from covLong; close &outlib..&prefix._covariance;
    create &outlib..&prefix._basis from basisLong[colname={'Parameter' 'ActiveColumn' 'Value'}];
      append from basisLong; close &outlib..&prefix._basis;
    create &outlib..&prefix._bread from breadLong[colname={'Row' 'Col' 'Value'}];
      append from breadLong; close &outlib..&prefix._bread;
    create &outlib..&prefix._archive from archive[colname={'Cluster' 'Row' 'Col' 'Gram' 'Adjustment'}];
      append from archive; close &outlib..&prefix._archive;
    create &outlib..&prefix._inference from inference[colname={'Contrast' 'ContrastStatus'
      'Estimate' 'StdErr' 'DF' 'tValue' 'Probt' 'Lower' 'Upper' 'Variance' 'ReferenceVariance' 'MaxReferenceShare'}];
      append from inference; close &outlib..&prefix._inference;
    create &outlib..&prefix._diagnostics from diagnostics[colname={'Cluster' 'LocalRank'
      'RootError' 'RootIterations' 'MaxLeverage'}];
      append from diagnostics; close &outlib..&prefix._diagnostics;
    create &outlib..&prefix._solution from bl[colname={'Parameter' 'Estimate'}];
      append from bl; close &outlib..&prefix._solution;
    Tau2=working[1,1]; Sigma2=working[1,2]; Alpha=working[1,3];
    DesignRank=r; ParameterCount=p; ClusterCount=m;
    create &outlib..&prefix._context var {RunId FitId Scope Tau2 Sigma2 Alpha DesignRank ParameterCount ClusterCount};
      append; close &outlib..&prefix._context;
  finish;
  dummy=0; run cr2Interface(dummy);
   
  create &outlib..&prefix._status var {RunId FitId Scope cr2rc};
    append; close &outlib..&prefix._status;
quit;
%mend;

%macro rbc_cr2_moment_modules;
start cr2Pairs(n);
  out=j(n*(n+1)/2,3,0); pos=0;
  do aa=1 to n; do bb=aa to n;
    pos=pos+1; out[pos,]=aa||bb||sqrt(2-(aa=bb));
  end; end;
  return(out);
finish;
start cr2SymSquarePairs(mat,pairA,pairB);
  out=j(nrow(pairA),nrow(pairB),0); us=pairB[,1]`; vs=pairB[,2]`;
  do pos=1 to nrow(pairA);
    aa=pairA[pos,1]; bb=pairA[pos,2];
    factor=.5*pairA[pos,3]*pairB[,3]`;
    out[pos,]=factor#(mat[aa,us]#mat[bb,vs]+mat[bb,us]#mat[aa,vs]);
  end;
  return(out);
finish;
start cr2SymSquare(mat);
  return(cr2SymSquarePairs(mat,cr2Pairs(nrow(mat)),cr2Pairs(ncol(mat))));
finish;
start cr2Svec(mat);
  pairs=cr2Pairs(nrow(mat)); out=j(nrow(pairs),1,0);
  do pos=1 to nrow(pairs);
    out[pos]=pairs[pos,3]*mat[pairs[pos,1],pairs[pos,2]];
  end;
  return(out);
finish;
start cr2Kahan(total,comp,increment);
  corrected=increment-comp; fresh=total+corrected;
  comp=(fresh-total)-corrected; total=fresh;
finish;
start cr2Normalize(E,B,C,Cnorm,N,rowScales) global(cr2rc);
  rank=ncol(E); q=nrow(C); p=nrow(E);
  if countmiss(E)+countmiss(B)+countmiss(C)>0 | q<1 | ncol(C)^=p |
     nrow(B)^=rank | ncol(B)^=rank then do; cr2rc='INVALID_JOINT_INPUT'; return; end;
  if max(abs(E`*E-i(rank)))>2e-9 then do; cr2rc='INVALID_DESIGN_BASIS'; return; end;
  if q>rank then do; cr2rc='REDUNDANT_CONSTRAINTS'; return; end;
  squared=C#C; rowScales=sqrt(squared[,+]);
  if min(rowScales)<=0 then do; cr2rc='REDUNDANT_CONSTRAINTS'; return; end;
  scaled=C/repeat(rowScales,1,p); active=scaled*E;
  call svd(su,sv,svv,scaled-active*E`);
  call svd(cu,cv,cvv,scaled);
  if max(sv)>2e-8*max(cv) then do; cr2rc='NONESTIMABLE_CONTRAST'; return; end;
  call svd(au,av,avv,active`);
  if min(av)<=1e-10*max(av) then do; cr2rc='REDUNDANT_CONSTRAINTS'; return; end;

  Bh=cr2Power(B,.5); if cr2rc^='PASS' then return;
  call svd(nu,ns,nv,(active*Bh)`);
  if min(ns)<=1e-6*max(ns) then do; cr2rc='SINGULAR_REFERENCE_CONTRAST'; return; end;
  N=cr2Sym(nv*diag(1/ns)*nv`);
  polar=nv*nu`; Cnorm=solve(Bh`,polar`)`;
finish;
start cr2MomentArchive(E,B,allG,allD,activeCov,C,method,
                       M,Vnorm,weightTransform,contrastBasis,envelope) global(cr2rc);
  rank=ncol(E); persons=nrow(allG)/rank;
  if persons<2 | persons^=round(persons) | ncol(allG)^=rank |
     nrow(allD)^=nrow(allG) | ncol(allD)^=rank |
     countmiss(allG)+countmiss(allD)+countmiss(activeCov)>0 then do;
    cr2rc='CLUSTER_ALIGNMENT'; return;
  end;
  if method^='FAST' & method^='STABLE' then do; cr2rc='INVALID_MOMENT_METHOD'; return; end;
  run cr2Normalize(E,B,C,Cnorm,N,rowScales); if cr2rc^='PASS' then return;
  h=nrow(C); dim=h*(h+1)/2; dr=rank*(rank+1)/2;
  if 8*(4*dim*dr+6*dim*dim)>512*2##20 then do;
    cr2rc='MOMENT_ARCHIVE_SIZE_LIMIT'; return;
  end;
  T=B*Cnorm`; Bh=cr2Power(B,.5); if cr2rc^='PASS' then return;
  pairH=cr2Pairs(h); pairR=cr2Pairs(rank);
  Ksum=j(dim,dr,0); Kcomp=Ksum; Msum=j(dim,dim,0); Mcomp=Msum;
  correction=Msum; correctionComp=Msum; reference=j(h,h,0); normBudget=0;
  do person=1 to persons;
    gram=allG[((person-1)*rank+1):(person*rank),];
    adjustment=allD[((person-1)*rank+1):(person*rank),];
    Hii=cr2Sym(T`*gram*T); Li=T`*adjustment*Bh;
    reference=reference+Hii;
    Ki=cr2SymSquarePairs(Li,pairH,pairR);
    diagonal=cr2SymSquarePairs(Hii,pairH,pairH);
    if method='STABLE' then do;
      crossTerm=Ki*Ksum`; increment=diagonal+crossTerm+crossTerm`;
      normBudget=normBudget+cr2Norm(diagonal)+2*cr2Norm(crossTerm);
    end;
    else do;
      increment=diagonal; remove=cr2SymSquarePairs(Li*Li`,pairH,pairH);
      run cr2Kahan(correction,correctionComp,remove);
      normBudget=normBudget+cr2Norm(diagonal)+cr2Norm(remove);
    end;
    run cr2Kahan(Msum,Mcomp,increment);
    run cr2Kahan(Ksum,Kcomp,Ki);
  end;
  if max(abs(reference-i(h))-2e-8*abs(i(h)))>1e-9 then do;
    cr2rc='REFERENCE_EXPECTATION_NOT_IDENTITY'; return;
  end;
  if method='FAST' then do;
    allPairs=Ksum*Ksum`; Msum=Msum+allPairs-correction;
    normBudget=normBudget+cr2Norm(allPairs);
  end;
  M=cr2Sym(Msum); envelope=constant('MACEPS')*(64+8*persons)*normBudget;
  call eigen(mw,mu,M);
  if min(mw)<-envelope then do; cr2rc='NON_PSD_GAUSSIAN_MOMENT'; return; end;
  Vnorm=cr2Sym(Cnorm*activeCov*Cnorm`);
  weightTransform=solve(N`,diag(rowScales));
  contrastBasis=Cnorm*E`;
finish;
start cr2ArchiveScalar(weights,weightTransform,M,Vnorm,envelope,out) global(cr2rc);
  h=nrow(weightTransform);
  if ncol(weights)^=h | countmiss(weights)>0 then do; cr2rc='INVALID_ARCHIVE_WEIGHTS'; return; end;
  normalized=weights*weightTransform`; out=j(nrow(weights),6,.);
  pairs=cr2Pairs(h); dim=nrow(pairs);

  do first=1 to nrow(weights) by 128;
    last=min(first+127,nrow(weights)); ids=first:last; w=normalized[ids,];
    square=w#w; target=square[,+]; kv=j(nrow(w),dim,0);
    do pos=1 to dim;
      kv[,pos]=pairs[pos,3]*w[,pairs[pos,1]]#w[,pairs[pos,2]];
    end;
    products=kv#(kv*M); denominator=products[,+]; square=kv#kv; support=envelope*square[,+];
    products=w#(w*Vnorm); variance=products[,+];
    do row=1 to nrow(w);
      ci=ids[row]; out[ci,1:2]=ci||0;
      if target[row]<=0 then out[ci,2]=2;
      else if denominator[row]<=0 | support[row]>2e-8*denominator[row] then out[ci,2]=4;
      else out[ci,3:6]=(target[row]*target[row]/denominator[row])||variance[row]||target[row]||denominator[row];
    end;
  end;
finish;
start cr2ArchiveHTZ(weights,null,weightTransform,M,Vnorm,betaNorm,envelope,out) global(cr2rc);
  q=nrow(weights); h=nrow(weightTransform);
  out=j(1,9,.); out[1]=0;
  if q<1 | ncol(weights)^=h | countmiss(weights)+countmiss(null)>0 |
     nrow(null)^=q | ncol(null)^=1 | nrow(betaNorm)^=h then do;
    cr2rc='INVALID_JOINT_INPUT'; return;
  end;
  if q>h then do; cr2rc='REDUNDANT_CONSTRAINTS'; return; end;
  w=weights*weightTransform`; squared=w#w; scales=sqrt(squared[,+]);
  if min(scales)<=0 then do; cr2rc='REDUNDANT_CONSTRAINTS'; return; end;
  w=w/repeat(scales,1,h); nullScaled=null/scales;
  call svd(su,sv,svv,w`);
  if min(sv)<=1e-10*max(sv) then do; cr2rc='REDUNDANT_CONSTRAINTS'; return; end;
  if min(sv)<=1e-6*max(sv) then do; cr2rc='REDUNDANT_CONSTRAINTS'; return; end;
  normalizer=cr2Sym(svv*diag(1/sv)*svv`);
  wn=normalizer*w; symTransform=cr2SymSquare(wn);
  Mjoint=symTransform*M*symTransform`; denominator=2*trace(Mjoint);
  support=envelope*ssq(symTransform);
  if denominator<=0 | support>2e-8*denominator then do;
    cr2rc='MOMENT_ARCHIVE_SUPPORT_UNRESOLVED'; return;
  end;
  nu=q*(q+1)/denominator; df2=nu-q+1;
  observed=cr2Sym(wn*Vnorm*wn`); inverse=cr2Power(observed,-1);
  if cr2rc^='PASS' then do; cr2rc='SINGULAR_OBSERVED_CONTRAST_COV'; return; end;
  theta=normalizer*(w*betaNorm-nullScaled); wald=theta`*inverse*theta;
  if wald<0 | wald=. then do; cr2rc='INVALID_WALD_STATISTIC'; return; end;
  out[2:6]=q||nu||q||df2||wald; out[9]=denominator;
  if df2<=0 then out[1]=2;
  else do;
    if df2<4 then out[1]=1;
    fvalue=df2*wald/(nu*q); pvalue=sdf('F',fvalue,q,df2);
    out[7:8]=fvalue||pvalue;
  end;
finish;
%mend;

%macro rbc_person_cluster_stream(wide=,solution=,contrasts=,span=,context=,
                                outlib=WORK,prefix=stream,statistics=GRAM);
%local _ds _p _obs _live _close _xvars _j _members _member _statkind;
%let _statkind=%upcase(&statistics);
%if &_statkind ne GRAM and &_statkind ne QR %then %abort cancel;
%let _members=covariance basis bread moment spanbasis spanrobust inference solution context root_summary status;
%if not %sysfunc(nvalid(&prefix,V7)) or %length(&prefix)>16 or
    not %sysfunc(nvalid(&outlib,V7)) %then %abort cancel;
%do _j=1 %to %sysfunc(countw(&_members));
  %let _member=%scan(&_members,&_j);
  %if %sysfunc(exist(&outlib..&prefix._&_member)) %then %abort cancel;
%end;
%let _ds=%sysfunc(open(&solution,i));
%if &_ds=0 %then %abort cancel;
%let _p=%sysfunc(attrn(&_ds,NLOBS)); %let _close=%sysfunc(close(&_ds));
%if &_p<1 or &_p>200 %then %abort cancel;
%let _ds=%sysfunc(open(&wide,i));
%if &_ds=0 %then %abort cancel;
%let _obs=%sysfunc(attrn(&_ds,NOBS)); %let _live=%sysfunc(attrn(&_ds,NLOBS));
%let _close=%sysfunc(close(&_ds));
%let _xvars=K0;
%do _j=1 %to &_p; %let _xvars=&_xvars RBCX&_j; %end;
proc iml;
  %rbc_cr2_iml_modules; %rbc_cr2_moment_modules;
  %if &_statkind=QR %then %do; %rbc_qr_iml_modules; %end;
  cr2rc=repeat(' ',1,64); cr2rc='PASS';
  start csLong(dat,nr,nc) global(cr2rc);
    result=j(nr,nc,.);
    if nrow(dat)^=nr*nc | countmiss(dat)>0 then do; cr2rc='SMALL_MATRIX_CARDINALITY'; return(result); end;
    do ix=1 to nrow(dat);
      rr=dat[ix,1]; cc=dat[ix,2];
      if rr<1 | rr>nr | cc<1 | cc>nc | rr^=round(rr) | cc^=round(cc) then do;
        cr2rc='SMALL_MATRIX_INDEX'; return(result);
      end;
      if result[rr,cc]^=. then do; cr2rc='DUPLICATE_SMALL_MATRIX_CELL'; return(result); end;
      result[rr,cc]=dat[ix,3];
    end;
    return(result);
  finish;
  start csRI(rawGram,resCross,tau2,sigma2,gram,score) global(cr2rc);
    run cr2PSD(rawGram,gw,gu); if cr2rc^='PASS' then return;
    k=nrow(rawGram); n=rawGram[1,1]; sx=rawGram[2:k,1];
    if n<1 | n^=round(n) then do; cr2rc='INVALID_CLUSTER_SIZE'; return; end;
    centered=cr2Sym(rawGram[2:k,2:k]-sx*sx`/n);
    gram=cr2Sym(centered/sigma2+sx*sx`/(n*(sigma2+n*tau2)));
    run cr2PSD(gram,gw,gu); if cr2rc^='PASS' then return;
    score=(resCross[2:k]-sx*resCross[1]/n)/sigma2+sx*resCross[1]/(n*(sigma2+n*tau2));
  finish;
  start csBlock(block,person,k,rawGram,resCross,factorK,factorResidual) global(cr2rc);
    %if &_statkind=QR %then %do;
      q=k+1;
      if nrow(block)^=q | ncol(block)^=q+3 | countmiss(block)>0 then do;
        cr2rc='QR_BLOCK_DIMENSIONS'; return;
      end;
      n=block[1,3];
      if any(block[,1]^=person) | any(block[,2]^=(1:q)`) | any(block[,3]^=n) |
         n<1 | n^=round(n) then do; cr2rc='QR_CLUSTER_ROW_COUNT'; return; end;
      factorK=block[,4:(q+2)]; factorResidual=block[,q+3];
      rawGram=cr2Sym(factorK`*factorK); resCross=factorK`*factorResidual;
      if abs(rawGram[1,1]-n)>128*constant('MACEPS')*q*n then do;
        cr2rc='QR_INTERCEPT_COUNT'; return;
      end;
    %end;
    %else %do;
      if nrow(block)^=k | ncol(block)^=k+3 | countmiss(block)>0 then do;
        cr2rc='WIDE_BLOCK_DIMENSIONS'; return;
      end;
      if any(block[,1]^=person) | any(block[,2]^=(1:k)`) then do;
        cr2rc='WIDE_CLUSTER_ROW_ORDER'; return;
      end;
      rawGram=block[,3:(k+2)]; resCross=block[,k+3];
      factorK=.; factorResidual=.;
    %end;
  finish;
  start csFactorRI(factorK,factorResidual,tau2,sigma2,gram,score,weightedX) global(cr2rc);
    k=ncol(factorK); q1=factorK[,1]; n=ssq(q1); X=factorK[,2:k];
    sx=X`*q1; sr=q1`*factorResidual;
    weightedX=(X-q1*sx`/n)/sqrt(sigma2)+q1*sx`/(n*sqrt(sigma2+n*tau2));
    weightedResidual=(factorResidual-q1*sr/n)/sqrt(sigma2)+q1*sr/(n*sqrt(sigma2+n*tau2));
    gram=cr2Sym(weightedX`*weightedX); score=weightedX`*weightedResidual;
    run cr2PSD(gram,gw,gu);
  finish;
  start csMain(dummy) global(cr2rc,RunId,FitId,Scope);
    use &context; read all var {RunId FitId Scope}; read all var {Tau2 Sigma2 Alpha} into target; close &context;
    if nrow(RunId)^=1 | nrow(FitId)^=1 | nrow(Scope)^=1 | nrow(target)^=1 then do;
      cr2rc='CONTEXT_CARDINALITY'; return;
    end;
    if (Scope^='SYNTHETIC_DATA_ONLY' & Scope^='LOCAL_SAMPLE_MODEL_INFERENCE' & Scope^='FULL_COHORT_MODEL_INFERENCE') | length(strip(RunId))^=32 | length(strip(FitId))<1 then do;
      cr2rc='CONTEXT_SCOPE'; return;
    end;
    %if &_statkind=QR %then %do;
      use &context; read all var {StatisticKind} into statisticInput; close &context;
      if nrow(statisticInput)^=1 | statisticInput^='AUGMENTED_QR' then do; cr2rc='QR_STATISTIC_KIND'; return; end;
    %end;
    tau2=target[1,1]; sigma2=target[1,2]; alpha=target[1,3];
    if countmiss(target)>0 | tau2<0 | sigma2<=0 | alpha<=0 | alpha>=1 then do;
      cr2rc='WORKING_VARIANCES_OR_ALPHA'; return;
    end;
    p=&_p; k=p+1; blockRows=k; %if &_statkind=QR %then %do; blockRows=k+1; %end;
    persons=&_obs/blockRows; tiny=constant('SMALL');
    if &_obs^=&_live | persons<2 | persons^=round(persons) then do;
      cr2rc='WIDE_PHYSICAL_CARDINALITY'; return;
    end;
    use &solution; read all var {Parameter Estimate} into bl; close &solution;
    use &contrasts; read all var {Contrast Parameter Weight} into cl; close &contrasts;
    use &span; read all var {Span Parameter Weight} into sl; close &span;
    if countmiss(bl)+countmiss(cl)+countmiss(sl)>0 then do; cr2rc='MISSING_SMALL_MATRIX_INPUT'; return; end;
    if max(cl[,1])<1 | max(cl[,1])>200000 | max(cl[,1])^=round(max(cl[,1])) |
       max(sl[,1])<1 | max(sl[,1])>p | max(sl[,1])^=round(max(sl[,1])) then do;
      cr2rc='SMALL_MATRIX_SIZE_LIMIT'; return;
    end;
    beta=csLong(bl[,1]||j(p,1,1)||bl[,2],p,1); if cr2rc^='PASS' then return;
    C=csLong(cl,max(cl[,1]),p); if cr2rc^='PASS' then return;
    Cspan=csLong(sl,max(sl[,1]),p); if cr2rc^='PASS' then return;
    total=j(p,p,0); totalComp=total; sumScore=j(p,1,0); scoreComp=sumScore; scoreScale=0;
    globalFactor=j(p,p,0); kernelStatus=repeat(' ',1,64);
    use &wide;
    do person=1 to persons;
      points=((person-1)*blockRows+1):(person*blockRows);
      read point points var {Cluster Row %if &_statkind=QR %then %do; NObs %end; &_xvars Cross} into block;
      run csBlock(block,person,k,rawGram,resCross,factorK,factorResidual); if cr2rc^='PASS' then return;
      %if &_statkind=QR %then %do;
        run csFactorRI(factorK,factorResidual,tau2,sigma2,gram,score,weightedX);
      %end;
      %else %do; run csRI(rawGram,resCross,tau2,sigma2,gram,score); %end;
      if cr2rc^='PASS' then return;
      run cr2Kahan(total,totalComp,gram); run cr2Kahan(sumScore,scoreComp,score);
      %if &_statkind=QR %then %do;
         
        stack=globalFactor//weightedX;
        run rbcUntruncatedQR(stack,globalFactor,kernelStatus);
        if kernelStatus^='PASS' then do; cr2rc='GLOBAL_FACTOR_QR_FAILED'; return; end;
      %end;
      scoreScale=scoreScale+cr2Norm(score);
    end;
    close &wide;
    run cr2PSD(total,tw,tu); if cr2rc^='PASS' then return;
    if max(tw)<=0 then do; cr2rc='ZERO_DESIGN_RANK'; return; end;
    %if &_statkind=QR %then %do;
      call svd(globalU,globalS,globalV,globalFactor);
      keep=loc(globalS>1e-5*max(globalS)); E=globalV[,keep]; rank=ncol(E);
      B=diag(1/(globalS[keep]##2)); Bh=diag(1/globalS[keep]);
    %end;
    %else %do;
      keep=loc(tw>1e-10*max(tw)); E=tu[,keep]; rank=ncol(E); B=diag(1/tw[keep]); Bh=diag(1/sqrt(tw[keep]));
    %end;
    if cr2Norm(E`*sumScore)>2e-8*max(scoreScale,tiny) then do; cr2rc='SCORES_NOT_FROM_FITTED_GLS'; return; end;
    transform=j(k,rank+1,0); transform[1,1]=1; transform[2:k,2:(rank+1)]=E;
    run cr2Normalize(E,B,Cspan,Cnorm,N,rowScales); if cr2rc^='PASS' then return;
    h=nrow(Cspan); dim=h*(h+1)/2; dr=rank*(rank+1)/2;
    if 8*(4*dim*dr+6*dim*dim)>512*2##20 then do; cr2rc='MOMENT_ARCHIVE_SIZE_LIMIT'; return; end;
    momentT=B*Cnorm`; pairH=cr2Pairs(h); pairR=cr2Pairs(rank);
    Ksum=j(dim,dr,0); Kcomp=Ksum; Msum=j(dim,dim,0); Mcomp=Msum;
    correction=Msum; correctionComp=Msum; reference=j(h,h,0); normBudget=0;
    meat=j(rank,rank,0); meatComp=meat; maxLeverage=0; maxRootError=0; maxRootSteps=0;
    minLocalRank=rank+1; maxLocalRank=0; processed=0;
    use &wide;
    do person=1 to persons;
      points=((person-1)*blockRows+1):(person*blockRows);
      read point points var {Cluster Row %if &_statkind=QR %then %do; NObs %end; &_xvars Cross} into block;
      run csBlock(block,person,k,rawGram,resCross,factorK,factorResidual); if cr2rc^='PASS' then return;
      %if &_statkind=QR %then %do;
        run csFactorRI(factorK,factorResidual,tau2,sigma2,gram,score,weightedX);
      %end;
      %else %do; run csRI(rawGram,resCross,tau2,sigma2,gram,score); %end;
      if cr2rc^='PASS' then return;
      activeScore=E`*score;
      %if &_statkind=QR %then %do;
        activeWeighted=weightedX*E; activeGram=cr2Sym(activeWeighted`*activeWeighted);
      %end;
      %else %do; activeGram=cr2Sym(E`*gram*E); %end;
      if cr2Norm(score-E*activeScore)>2e-8*max(cr2Norm(score),tiny) then do; cr2rc='SCORE_OUTSIDE_DESIGN_SPACE'; return; end;
      run cr2PSD(Bh*activeGram*Bh,lw,lu); if cr2rc^='PASS' then return;
      maxLeverage=max(maxLeverage,max(lw));
      if max(lw)>=1-1e-10 then do; cr2rc='SATURATED_OR_NEAR_SATURATED'; return; end;
      %if &_statkind=QR %then %do;
        localFactor=factorK*transform;
        call svd(su,sv,svv,localFactor);
        cutoff=32*constant('MACEPS')*max(nrow(localFactor),ncol(localFactor))*max(sv);
        keep=loc(sv>cutoff);
        if ncol(keep)=0 then do; cr2rc='ZERO_LOCAL_QR_SPAN'; return; end;
        eig=sv[keep]; Rall=diag(eig)*svv[,keep]`; er=su[,keep]`*factorResidual;
      %end;
      %else %do;
        localGram=cr2Sym(transform`*rawGram*transform); localCross=transform`*resCross;
        run cr2PSD(localGram,hw,hu); if cr2rc^='PASS' then return;
        keep=loc(hw>1e-10*max(hw)); eig=hw[keep]; U=hu[,keep];
        if ncol(keep)=0 then do; cr2rc='ZERO_LOCAL_SPAN'; return; end;
        if cr2Norm(localCross-U*(U`*localCross))>2e-8*max(cr2Norm(localCross),tiny) then do; cr2rc='RESIDUAL_CROSS_OUTSIDE_LOCAL_SPAN'; return; end;
        Rall=diag(sqrt(eig))*U`; er=(U`*localCross)/sqrt(eig);
      %end;
      q1=Rall[,1]; projectX=Rall[,2:(rank+1)];
      V=sigma2*i(nrow(eig))+tau2*q1*q1`; weight=cr2Power(V,-1); if cr2rc^='PASS' then return;
      S=cr2Sym(V-projectX*B*projectX`);
      run cr2Root(V,S,A,rootError,steps); if cr2rc^='PASS' then return;
      if max(abs(projectX`*weight*er-activeScore)-2e-8*abs(activeScore))>1e-10 then do; cr2rc='PROJECTED_SCORE_MISMATCH'; return; end;
      adjusted=projectX`*weight*A*er; adjustment=projectX`*weight*A*projectX;
      run cr2Kahan(meat,meatComp,adjusted*adjusted`);
      Hii=cr2Sym(momentT`*activeGram*momentT); Li=momentT`*adjustment*Bh;
      reference=reference+Hii; Ki=cr2SymSquarePairs(Li,pairH,pairR);
      diagonal=cr2SymSquarePairs(Hii,pairH,pairH); remove=cr2SymSquarePairs(Li*Li`,pairH,pairH);
      run cr2Kahan(Msum,Mcomp,diagonal); run cr2Kahan(correction,correctionComp,remove); run cr2Kahan(Ksum,Kcomp,Ki);
      normBudget=normBudget+cr2Norm(diagonal)+cr2Norm(remove);
      maxRootError=max(maxRootError,rootError); maxRootSteps=max(maxRootSteps,steps);
      minLocalRank=min(minLocalRank,nrow(eig)); maxLocalRank=max(maxLocalRank,nrow(eig)); processed=processed+1;
    end;
    close &wide;
    if processed^=persons then do; cr2rc='INCOMPLETE_CLUSTER_PASS'; return; end;
    if max(abs(reference-i(h))-2e-8*abs(i(h)))>1e-9 then do; cr2rc='REFERENCE_EXPECTATION_NOT_IDENTITY'; return; end;
    allPairs=Ksum*Ksum`; M=cr2Sym(Msum+allPairs-correction); normBudget=normBudget+cr2Norm(allPairs);
    envelope=constant('MACEPS')*(64+8*persons)*normBudget;
    call eigen(mw,mu,M);
    if min(mw)<-envelope then do; cr2rc='NON_PSD_GAUSSIAN_MOMENT'; return; end;
    activeCov=cr2Sym(B*meat*B); cov=cr2Sym(E*activeCov*E`);
    Vnorm=cr2Sym(Cnorm*activeCov*Cnorm`); contrastBasis=Cnorm*E`;
    call svd(spanU,spanS,spanV,Cnorm`);
    if min(spanS)<=1e-6*max(spanS) then do; cr2rc='ILL_CONDITIONED_SCORE_SPAN'; return; end;
    rightInverse=spanU*diag(1/spanS)*spanV`;
    weights=C*E*rightInverse; codes=j(nrow(C),1,0);
    do ci=1 to nrow(C);
      cn=cr2Norm(C[ci,]);
      if cn=0 then codes[ci]=2;
      else if cr2Norm(C[ci,]-C[ci,]*E*E`)>2e-8*cn then codes[ci]=1;
      else if cr2Norm(C[ci,]-weights[ci,]*contrastBasis)>2e-8*cn then codes[ci]=5;
      if codes[ci]^=0 then weights[ci,]=0;
    end;
    run cr2ArchiveScalar(weights,i(h),M,Vnorm,envelope,scalar);
    if cr2rc^='PASS' then return;
    inference=j(nrow(C),12,.);
    do ci=1 to nrow(C);
      status=scalar[ci,2]; if codes[ci]^=0 then status=codes[ci];
      inference[ci,1:2]=ci||status;
      if status=0 then do;
        variance=scalar[ci,4];
        if variance<=0 then inference[ci,2]=3;
        else do;
          estimate=C[ci,]*beta; se=sqrt(variance); df=scalar[ci,3]; t=estimate/se;
          prob=2*cdf('T',-abs(t),df); critical=tinv(1-alpha/2,df);
          inference[ci,3:12]=estimate||se||df||t||prob||(estimate-critical*se)||(estimate+critical*se)||variance||scalar[ci,5]||.;
        end;
      end;
    end;

    covLong=j(p*p,3,0); basisLong=j(p*rank,3,0); breadLong=j(rank*rank,3,0);
    pos=0; do rr=1 to p; do cc=1 to p; pos=pos+1; covLong[pos,]=rr||cc||cov[rr,cc]; end; end;
    pos=0; do rr=1 to p; do cc=1 to rank; pos=pos+1; basisLong[pos,]=rr||cc||E[rr,cc]; end; end;
    pos=0; do rr=1 to rank; do cc=1 to rank; pos=pos+1; breadLong[pos,]=rr||cc||B[rr,cc]; end; end;
    create &outlib..&prefix._covariance from covLong[colname={'Row' 'Col' 'Value'}]; append from covLong; close &outlib..&prefix._covariance;
    create &outlib..&prefix._basis from basisLong[colname={'Parameter' 'ActiveColumn' 'Value'}]; append from basisLong; close &outlib..&prefix._basis;
    create &outlib..&prefix._bread from breadLong[colname={'Row' 'Col' 'Value'}]; append from breadLong; close &outlib..&prefix._bread;
    create &outlib..&prefix._moment from M; append from M; close &outlib..&prefix._moment;
    create &outlib..&prefix._spanbasis from contrastBasis; append from contrastBasis; close &outlib..&prefix._spanbasis;
    create &outlib..&prefix._spanrobust from Vnorm; append from Vnorm; close &outlib..&prefix._spanrobust;
    create &outlib..&prefix._inference from inference[colname={'Contrast' 'ContrastStatus' 'Estimate' 'StdErr' 'DF' 'tValue' 'Probt' 'Lower' 'Upper' 'Variance' 'ReferenceVariance' 'MaxReferenceShare'}]; append from inference; close &outlib..&prefix._inference;
    create &outlib..&prefix._solution from bl[colname={'Parameter' 'Estimate'}]; append from bl; close &outlib..&prefix._solution;
    rootSummary=processed||minLocalRank||maxLocalRank||maxRootError||maxRootSteps||maxLeverage;
    create &outlib..&prefix._root_summary from rootSummary[colname={'ClustersProcessed' 'MinLocalRank' 'MaxLocalRank' 'MaxRootError' 'MaxRootIterations' 'MaxLeverage'}]; append from rootSummary; close &outlib..&prefix._root_summary;
    StatisticKind='RAW_GRAM'; %if &_statkind=QR %then %do; StatisticKind='AUGMENTED_QR'; %end;
    DesignRank=rank; ParameterCount=p; ClusterCount=persons; SpanDimension=h; MomentDimension=dim; RoundoffEnvelope=envelope;
    create &outlib..&prefix._context var {RunId FitId Scope Tau2 Sigma2 Alpha DesignRank ParameterCount ClusterCount SpanDimension MomentDimension RoundoffEnvelope StatisticKind}; append; close &outlib..&prefix._context;
  finish;
  dummy=0; run csMain(dummy);
  create &outlib..&prefix._status var {RunId FitId Scope cr2rc}; append; close &outlib..&prefix._status;
quit;
%mend;

%macro rbc_moment_error_fast_modules;

start bmUp(v) global(boundrc);

  if countmiss(v)>0 then do; boundrc='NONFINITE_CERTIFICATE'; return(v); end;

  if min(v)<0 then do; boundrc='NEGATIVE_CERTIFICATE'; return(j(nrow(v),ncol(v),.)); end;

  z=(v+constant('SMALL'))*(1+8*constant('MACEPS'));

  if countmiss(z)>0 then boundrc='NONFINITE_CERTIFICATE';

  return(z);

finish;

start bmAdd(a,b); return(bmUp(a+b)); finish;

start bmMul(a,b); return(bmUp(a#b)); finish;

start bmDiv(a,b) global(boundrc);

  if countmiss(b)>0 | min(b)<=0 then do; boundrc='INVALID_CERTIFICATE_DIVISOR'; return(a#.); end;

  return(bmUp(a/b));

finish;

start bmLocal(value);

  return(bmAdd(bmMul(constant('MACEPS'),abs(value)),constant('SMALL')));

finish;

start bmDotRound(a,b) global(boundrc);

  n=ncol(a); ne=n*constant('MACEPS');

  if ne>=.125 then do; boundrc='OPERATION_COUNT_LIMIT'; return(j(nrow(a),ncol(b),.)); end;

  g=bmDiv(ne,1-ne);

  under=bmMul(4*n,constant('SMALL'));

  absolute=abs(a)*abs(b);

  upper=bmDiv(bmAdd(absolute,under),1-2*g);

  return(bmAdd(bmMul(g,upper),under));

finish;

start bmDotUp(a,b) global(boundrc);

  if countmiss(a)+countmiss(b)>0 | min(a)<0 | min(b)<0 then do;

    boundrc='INVALID_POSITIVE_PRODUCT'; return(j(nrow(a),ncol(b),.));

  end;

  positiveCentral=a*b;
  positiveRound=bmDotRound(a,b);
  positiveUpper=bmAdd(positiveCentral,positiveRound);
  return(positiveUpper);

finish;

start bmDot(a,ea,b,eb,value,error) global(boundrc);
  value=a*b;
  if countmiss(ea)+countmiss(eb)>0 | min(ea)<0 | min(eb)<0 then do;
    boundrc='INVALID_DOT_INPUT_ERROR'; error=j(nrow(a),ncol(b),.); return;
  end;
  error=bmDotRound(a,b);
  hasA=(max(ea)>0); hasB=(max(eb)>0);
  if hasB then error=bmAdd(error,bmDotUp(abs(a),eb));
  if hasA then error=bmAdd(error,bmDotUp(ea,abs(b)));
  if hasA & hasB then error=bmAdd(error,bmDotUp(ea,eb));
finish;

start bmSquare(a,ea,pairA,pairB,value,error);
  value=cr2SymSquarePairs(a,pairA,pairB);
  error=j(nrow(pairA),nrow(pairB),0);
  us=pairB[,1]`; vs=pairB[,2]`;
  block=max(1,floor(262144/nrow(pairB)));
  do first=1 to nrow(pairA) by block;
    last=min(nrow(pairA),first+block-1); rows=first:last;
    aa=pairA[rows,1]; bb=pairA[rows,2];
    factor=(.5*pairA[rows,3])*pairB[,3]`;
    ef=bmMul(8*constant('MACEPS'),abs(factor));
    a11=a[aa,us];a22=a[bb,vs];a21=a[bb,us];a12=a[aa,vs];
    e11=ea[aa,us];e22=ea[bb,vs];e21=ea[bb,us];e12=ea[aa,vs];
    p=a11#a22; q=a21#a12;
    ep=bmAdd(bmMul(abs(a11),e22),bmMul(abs(a22),e11));
    ep=bmAdd(ep,bmMul(e11,e22));ep=bmAdd(ep,bmLocal(p));
    eq=bmAdd(bmMul(abs(a21),e12),bmMul(abs(a12),e21));
    eq=bmAdd(eq,bmMul(e21,e12));eq=bmAdd(eq,bmLocal(q));
    s=p+q;es=bmAdd(bmAdd(ep,eq),bmLocal(s));
    e=bmAdd(bmMul(abs(factor),es),bmMul(abs(s),ef));
    e=bmAdd(e,bmMul(ef,es));
    error[rows,]=bmAdd(e,bmLocal(value[rows,]));
  end;
finish;

start bmKahan(total,comp,increment,inputError,accumError);

  corrected=increment-comp; fresh=total+corrected;

  difference=fresh-total; newComp=difference-corrected;

  local=bmAdd(bmLocal(corrected),bmLocal(difference));

  local=bmAdd(local,bmLocal(newComp));

  accumError=bmAdd(bmAdd(accumError,inputError),local);

  total=fresh; comp=newComp;

finish;

start bmKahanError(total,accumError);

  return(bmAdd(accumError,bmLocal(total)));

finish;

start bmFinish(msum,emsum,ksum,eksum,correction,ecorrection,m,em);

  run bmDot(ksum,eksum,ksum`,eksum`,allPairs,eallPairs);

  first=msum+allPairs; efirst=bmAdd(bmAdd(emsum,eallPairs),bmLocal(first));

  second=first-correction; esecond=bmAdd(bmAdd(efirst,ecorrection),bmLocal(second));

  twice=second+second`; etwice=bmAdd(bmAdd(esecond,esecond`),bmLocal(twice));

  m=twice/2; em=bmAdd(bmMul(.5,etwice),bmLocal(m));

finish;

start bmScalar(m,em,w,den,error);

  pairH=cr2Pairs(ncol(w));d=nrow(pairH);

  scale=pairH[,3]`;wa=w[,pairH[,1]];wb=w[,pairH[,2]];
  first=repeat(scale,nrow(w),1)#wa;kv=first#wb;
  es=bmMul(constant('MACEPS'),abs(scale));
  efirst=bmAdd(bmMul(abs(wa),repeat(es,nrow(w),1)),bmLocal(first));
  ekv=bmAdd(bmMul(abs(wb),efirst),bmLocal(kv));
  run bmDot(kv,ekv,m,em,product,eproduct);

  products=kv#product;

  ep=bmAdd(bmMul(abs(kv),eproduct),bmMul(abs(product),ekv));

  ep=bmAdd(bmAdd(ep,bmMul(ekv,eproduct)),bmLocal(products));

  den=products[,+]; ones=j(d,1,1);

  error=bmAdd(bmDotUp(ep,ones),bmDotRound(products,ones));

finish;

start bmHost(dummy) global(boundrc);

  boundrc='PASS';

  if putn(constant('MACEPS'),'hex16.')^='3CB0000000000000' |

     putn(sqrt(2),'hex16.')^='3FF6A09E667F3BCD' then boundrc='UNSUPPORTED_CERTIFICATE_HOST';

  small=constant('SMALL'); sub=small/2; big=2##1022;

  left=diag(sub||sub); right=diag(big||big); product=left*right;

  if putn(sub,'hex16.')^='0008000000000000' | max(abs(product-.5*i(2)))^=0 |

     1+constant('MACEPS')/2^=1 then boundrc='UNSUPPORTED_CERTIFICATE_ARITHMETIC';

finish;

start bmRecenter(original,center,error) global(boundrc);
  if nrow(original)^=nrow(center) | ncol(original)^=ncol(center) |
     nrow(original)^=nrow(error) | ncol(original)^=ncol(error) then do;
    boundrc='RECENTER_DIMENSION'; return(j(nrow(original),ncol(original),.));
  end;
  if countmiss(original)+countmiss(center)+countmiss(error)>0 | min(error)<0 then do;
    boundrc='INVALID_RECENTER_INPUT'; return(j(nrow(original),ncol(original),.));
  end;
  difference=original-center;
  return(bmAdd(error,bmUp(abs(difference))));
finish;

%mend;

%macro rbc_moment_probability_modules;
start rbcPBetaCF(a,b,x);
 qab=a+b; qap=a+1; qam=a-1; c=1; d=1-qab*x/qap;
 if d=0 | nmiss(d)>0 then return(.);
 d=1/d; hval=d; eps=constant('MACEPS'); stable=0;
 do m=1 to 10000;
  m2=2*m;
  aa=(m/(a+m2))*((b-m)/(qam+m2))*x;
  d=1+aa*d; c=1+aa/c;
  if d=0 | c=0 | nmiss(d,c)>0 then return(.);
  d=1/d; hval=hval*d*c;
  aa=-((a+m)/(a+m2))*((qab+m)/(qap+m2))*x;
  d=1+aa*d; c=1+aa/c;
  if d=0 | c=0 | nmiss(d,c)>0 then return(.);
  d=1/d; delta=d*c; hval=hval*delta;
  if nmiss(hval,delta)>0 | hval<=0 then return(.);
  if abs(delta-1)<=4*eps then stable=stable+1; else stable=0;
  if stable>=2 then return(hval);
 end;
 return(.);
finish;
start rbcPBetaSmall(a,b,x,logx,logone);
 cf=rbcPBetaCF(a,b,x);
 if nmiss(cf)>0 then return(.);
 if a<0.5 then lnab=lgamma(1+a)+lgamma(b)-lgamma(a+b);
 else lnab=logbeta(a,b)+log(a);
 lp=a*logx+b*logone-lnab+log(cf);
 if nmiss(lp)>0 then return(.);
 answer=exp(lp);
 if nmiss(answer)>0 | answer<0 | answer>1 then return(.);
 return(answer);
finish;
start rbcPFTail(f,q,df);
 if nmiss(f,q,df)>0 | f<0 | q<=0 | df<=0 then return(.);
 if f=0 then return(1);
 if f>constant('BIG')/q then return(.);
 product=q*f;
 if nmiss(product)>0 | product<=0 then return(.);
 if product<=df then do;
  ratio=product/df; if ratio<=0 then return(.);
  x=1/(1+ratio); y=ratio/(1+ratio);
  logx=-log1px(ratio); logy=log(ratio)-log1px(ratio);
 end;
 else do;
  ratio=df/product; if ratio<=0 then return(.);
  x=ratio/(1+ratio); y=1/(1+ratio);
  logx=log(ratio)-log1px(ratio); logy=-log1px(ratio);
 end;
 a=df/2; b=q/2;
 if a<=0 | b<=0 then return(.);
 if x<(a+1)/(a+b+2) then answer=rbcPBetaSmall(a,b,x,logx,logy);
 else do; lower=rbcPBetaSmall(b,a,y,logy,logx); if nmiss(lower)>0 then return(.); answer=1-lower; end;
 return(answer);
finish;

start cr2FTail(f,q,df);
 if nmiss(f,q,df)>0 | f<0 | q<1 | q>36 | q^=int(q) | df<=0 then return(.);
 if f=0 then return(1);
 if df>=1 then answer=sdf('F',f,q,df);
 else answer=rbcPFTail(f,q,df);
 if nmiss(answer)>0 | answer<0 | answer>1 then return(.);
 return(answer);
finish;
%mend;

%macro rbc_certified_inference_modules;
%rbc_moment_probability_modules;
start cr2CertifiedRatio(den,error,ratio,lower,resolved) global(cr2rc,boundrc);
  ratio=.; lower=.; resolved=0;
  if countmiss(den)+countmiss(error)>0 | error<0 then do;
    cr2rc='MOMENT_ENTRYWISE_CERTIFICATE_INPUT'; return;
  end;
  if den<=0 then return;
  ratio=bmDiv(error,den);
  if ratio<.25 then do;
    divisor=1-2*max(ratio,constant('MACEPS'));
    lower=bmDiv(ratio,divisor);
    resolved=(lower<=2e-8);
  end;
  if boundrc^='PASS' then cr2rc='MOMENT_ENTRYWISE_BOUND_FAILURE';
finish;
start cr2CertifiedScalar(weights,weightTransform,M,Vnorm,EM,out,cert,nativeWeights) global(cr2rc,boundrc);
  h=nrow(weightTransform); d=h*(h+1)/2;
  if ncol(weights)^=h | countmiss(weights)>0 | nrow(M)^=d | ncol(M)^=d |
     nrow(EM)^=d | ncol(EM)^=d | countmiss(M)+countmiss(EM)>0 | min(EM)<0 then do;
    cr2rc='INVALID_ARCHIVE_WEIGHTS_OR_BOUND'; return;
  end;
  normalized=weights*weightTransform`; nativeWeights=normalized; out=j(nrow(weights),6,.);
  cert=j(nrow(weights),6,.); cert[,6]=0; pairs=cr2Pairs(h);
  do first=1 to nrow(weights) by 128;
    last=min(first+127,nrow(weights)); ids=first:last; w=normalized[ids,];
    square=w#w; target=square[,+]; kv=j(nrow(w),d,0);
    do pos=1 to d;
      kv[,pos]=pairs[pos,3]*w[,pairs[pos,1]]#w[,pairs[pos,2]];
    end;
    products=kv#(kv*M); denominator=products[,+];
    products=w#(w*Vnorm); variance=products[,+];
    run bmScalar(M,EM,w,helperDen,helperError);
    do row=1 to nrow(w);
      ci=ids[row]; out[ci,1:2]=ci||0; cert[ci,1]=ci;
      if target[row]<=0 then out[ci,2]=2;
      else do;
        error=bmRecenter(denominator[row],helperDen[row],helperError[row]);
        run cr2CertifiedRatio(denominator[row],error,ratio,lower,resolved);
        if cr2rc^='PASS' then return;
        cert[ci,2:6]=denominator[row]||error||ratio||lower||resolved;
        if resolved^=1 then out[ci,2]=4;
        else out[ci,3:6]=(target[row]*target[row]/denominator[row])||
                          variance[row]||target[row]||denominator[row];
      end;
    end;
  end;
finish;

start cr2DF2Interval(den,error,q,nuLo,nuHi,dfLo,dfHi,signCode) global(boundrc);
  nuLo=.;nuHi=.;dfLo=.;dfHi=.;signCode=2;
  if countmiss(den)+countmiss(error)>0 | den<=0 | error<0 | q<1 then return;
  upper=bmAdd(den,error);
  rounded=den-error;radius=bmLocal(rounded);lower=rounded-2*radius;
  if lower<=0 | countmiss(lower)+countmiss(upper)>0 then return;
  numerator=q*(q+1);
  rounded=numerator/upper;radius=bmLocal(rounded);nuLo=max(0,rounded-2*radius);
  nuHi=bmDiv(numerator,lower);
  rounded=nuLo-(q-1);radius=bmLocal(rounded);dfLo=rounded-2*radius;
  rounded=nuHi-(q-1);radius=bmLocal(rounded);dfHi=rounded+2*radius;
  if countmiss(nuLo)+countmiss(nuHi)+countmiss(dfLo)+countmiss(dfHi)>0 then do;
    nuLo=.;nuHi=.;dfLo=.;dfHi=.;return;
  end;
  signCode=0;
  if dfLo>0 then signCode=1;
  else if dfHi<=0 then signCode=-1;
finish;

start cr2CertifiedHTZ(weights,null,weightTransform,M,Vnorm,betaNorm,EM,out,cert,nativeWn)
 global(cr2rc,boundrc);
  q=nrow(weights); h=nrow(weightTransform); d=h*(h+1)/2;
  out=j(1,9,.); out[1]=0; cert=j(1,10,.);cert[5]=0;cert[10]=2;nativeWn=j(q,h,.);
  if q<1 | ncol(weights)^=h | countmiss(weights)+countmiss(null)>0 |
     nrow(null)^=q | ncol(null)^=1 | nrow(betaNorm)^=h |
     nrow(M)^=d | ncol(M)^=d | nrow(EM)^=d | ncol(EM)^=d |
     countmiss(M)+countmiss(EM)>0 | min(EM)<0 then do;
    cr2rc='INVALID_JOINT_INPUT_OR_BOUND'; return;
  end;
  if q>h then do; cr2rc='REDUNDANT_CONSTRAINTS'; return; end;
  w=weights*weightTransform`; squared=w#w; scales=sqrt(squared[,+]);
  if min(scales)<=0 then do; cr2rc='REDUNDANT_CONSTRAINTS'; return; end;
  w=w/repeat(scales,1,h); nullScaled=null/scales;
  call svd(su,sv,svv,w`);
  if min(sv)<=1e-10*max(sv) then do; cr2rc='REDUNDANT_CONSTRAINTS'; return; end;
  if min(sv)<=1e-6*max(sv) then do; cr2rc='REDUNDANT_CONSTRAINTS'; return; end;
  normalizer=cr2Sym(svv*diag(1/sv)*svv`);
  wn=normalizer*w; nativeWn=wn; symTransform=cr2SymSquare(wn);
  Mjoint=symTransform*M*symTransform`; denominator=2*trace(Mjoint);
  pairQ=cr2Pairs(q); pairH=cr2Pairs(h); zeros=j(q,h,0);
  run bmSquare(wn,zeros,pairQ,pairH,helperS,helperSE);
  ES=bmRecenter(symTransform,helperS,helperSE);
  run bmDot(symTransform,ES,M,EM,helperProduct,helperProductE);
  run bmDot(helperProduct,helperProductE,symTransform`,ES`,helperJoint,helperJointE);
  EJoint=bmRecenter(Mjoint,helperJoint,helperJointE);
  diagonal=vecdiag(Mjoint)`; errorDiagonal=vecdiag(EJoint)`;
  ones=j(ncol(diagonal),1,1); summed=diagonal[,+];
  sumError=bmAdd(bmDotUp(errorDiagonal,ones),bmDotRound(diagonal,ones));
  traceError=bmRecenter(trace(Mjoint),summed,sumError);
  denominatorError=bmAdd(bmMul(2,traceError),bmLocal(denominator));
  run cr2CertifiedRatio(denominator,denominatorError,ratio,lower,resolved);
  if cr2rc^='PASS' then return;
  cert[1:5]=denominator||denominatorError||ratio||lower||resolved;
  run cr2DF2Interval(denominator,denominatorError,q,nuLo,nuHi,dfLo,dfHi,dfSign);
  if boundrc^='PASS' then do;cr2rc='MOMENT_ENTRYWISE_BOUND_FAILURE';return;end;
  cert[6:10]=nuLo||nuHi||dfLo||dfHi||dfSign;
  out[2]=q;out[4]=q;out[9]=denominator;
  if denominator>0 then do;
    nu=q*(q+1)/denominator; df2=nu-q+1;
    out[3]=nu;out[5]=df2;
  end;
   
  if resolved^=1 then do;out[1]=4;return;end;
  observed=cr2Sym(wn*Vnorm*wn`); inverse=cr2Power(observed,-1);
  if cr2rc^='PASS' then do; cr2rc='SINGULAR_OBSERVED_CONTRAST_COV'; return; end;
  theta=normalizer*(w*betaNorm-nullScaled); wald=theta`*solve(observed,theta);
  if wald<0 | wald=. then do; cr2rc='INVALID_WALD_STATISTIC'; return; end;
  out[2:6]=q||nu||q||df2||wald; out[9]=denominator;
  if dfSign=0 | dfSign=2 then out[1]=5;
  else if df2<=0 then out[1]=2;
  else do;
    if df2<4 then out[1]=1;
    fvalue=df2*wald/(nu*q); pvalue=cr2FTail(fvalue,q,df2);
    if pvalue=. | pvalue<0 | pvalue>1 then do;
      cr2rc='F_DISTRIBUTION_EVALUATION_FAILED';return;
    end;
    out[7:8]=fvalue||pvalue;
  end;
finish;
%mend;

%macro rbc_person_cluster_white_stream(wide=,support=,solution=,contrasts=,span=,context=,
                                outlib=WORK,prefix=wstream);
%local _ds _p _obs _live _close _xvars _j _members _member _svars _sobs _slive _ctxobs _rbc_iml_cpu;
%let _members=covariance basis bread moment spanbasis spanrobust inference solution context root_summary status moment_error scalar_weights scalar_certificate;
%if not %sysfunc(nvalid(&prefix,V7)) or %length(&prefix)>13 or
    not %sysfunc(nvalid(&outlib,V7)) %then %abort cancel;
%do _j=1 %to %sysfunc(countw(&_members));
  %let _member=%scan(&_members,&_j);
  %if %sysfunc(exist(&outlib..&prefix._&_member,DATA)) or %sysfunc(exist(&outlib..&prefix._&_member,VIEW)) %then %abort cancel;
%end;
%let _ds=%sysfunc(open(&solution,i));
%if &_ds=0 %then %abort cancel;
%let _p=%sysfunc(attrn(&_ds,NLOBS)); %let _close=%sysfunc(close(&_ds));
%if &_p<1 or &_p>200 %then %abort cancel;
%let _ds=%sysfunc(open(&wide,i));
%if &_ds=0 %then %abort cancel;
%let _obs=%sysfunc(attrn(&_ds,NOBS)); %let _live=%sysfunc(attrn(&_ds,NLOBS));
%let _close=%sysfunc(close(&_ds));
%if not %sysfunc(exist(&support,DATA)) or %sysfunc(exist(&support,VIEW)) %then %abort cancel;
%let _ds=%sysfunc(open(&support,i)); %if &_ds=0 %then %abort cancel;
%let _sobs=%sysfunc(attrn(&_ds,NOBS)); %let _slive=%sysfunc(attrn(&_ds,NLOBS));
%let _close=%sysfunc(close(&_ds));
%let _svars=; %do _j=1 %to &_p; %let _svars=&_svars HasX&_j; %end;
%let _ds=%sysfunc(open(&context,i)); %if &_ds=0 %then %abort cancel;
%let _ctxobs=%sysfunc(attrn(&_ds,NLOBS)); %let _close=%sysfunc(close(&_ds));
%let _xvars=K0;
%do _j=1 %to &_p; %let _xvars=&_xvars RBCX&_j; %end;

%let _rbc_iml_cpu=%sysfunc(getoption(cpucount,keyword));
options cpucount=1;
proc iml;
  %rbc_cr2_iml_modules; %rbc_cr2_moment_modules; %rbc_moment_error_fast_modules; %rbc_certified_inference_modules;
   %rbc_qr_iml_modules; 
  cr2rc=repeat(' ',1,64); cr2rc='NOT_COMPLETED'; completed=0;
  RunId=repeat(' ',1,32); FitId=repeat(' ',1,32); Scope=repeat(' ',1,32);
  start csLong(dat,nr,nc) global(cr2rc);
    result=j(nr,nc,.);
    if nrow(dat)^=nr*nc | countmiss(dat)>0 then do; cr2rc='SMALL_MATRIX_CARDINALITY'; return(result); end;
    do ix=1 to nrow(dat);
      rr=dat[ix,1]; cc=dat[ix,2];
      if rr<1 | rr>nr | cc<1 | cc>nc | rr^=round(rr) | cc^=round(cc) then do;
        cr2rc='SMALL_MATRIX_INDEX'; return(result);
      end;
      if result[rr,cc]^=. then do; cr2rc='DUPLICATE_SMALL_MATRIX_CELL'; return(result); end;
      result[rr,cc]=dat[ix,3];
    end;
    return(result);
  finish;
  start csBlock(block,person,k,rawGram,resCross,factorK,factorResidual) global(cr2rc);
    
      q=k+1;
      if nrow(block)^=q | ncol(block)^=q+3 | countmiss(block)>0 then do;
        cr2rc='QR_BLOCK_DIMENSIONS'; return;
      end;
      n=block[1,3];
      if any(block[,1]^=person) | any(block[,2]^=(1:q)`) | any(block[,3]^=n) |
         n<1 | n^=round(n) then do; cr2rc='QR_CLUSTER_ROW_COUNT'; return; end;
      factorK=block[,4:(q+2)]; factorResidual=block[,q+3];
      rawGram=cr2Sym(factorK`*factorK); resCross=factorK`*factorResidual;
      if abs(rawGram[1,1]-n)>128*constant('MACEPS')*q*n then do;
        cr2rc='QR_INTERCEPT_COUNT'; return;
      end;
    
  finish;
  start csFactorRI(factorK,factorResidual,tau2,sigma2,gram,score,weightedX) global(cr2rc);
    k=ncol(factorK); q1=factorK[,1]; n=ssq(q1); X=factorK[,2:k];
    sx=X`*q1; sr=q1`*factorResidual;
    weightedX=(X-q1*sx`/n)/sqrt(sigma2)+q1*sx`/(n*sqrt(sigma2+n*tau2));
    weightedResidual=(factorResidual-q1*sr/n)/sqrt(sigma2)+q1*sr/(n*sqrt(sigma2+n*tau2));
    gram=cr2Sym(weightedX`*weightedX); score=weightedX`*weightedResidual;
    run cr2PSD(gram,gw,gu);
  finish;
   
  start wsOrth(input,Q,d) global(cr2rc);
    if nrow(input)>=ncol(input) then do;
      call svd(ou,os,ov,input); candidates=ou;
    end;
    else do; call svd(ou,os,ov,input`); candidates=ov; end;
    cutoff=128*constant('MACEPS')*max(nrow(input),ncol(input))*max(os);
    kept=loc(os>cutoff); d=ncol(kept); Q=j(nrow(input),1,0);
    if d>0 then Q=candidates[,kept];
  finish;
  start wsComplement(Q,other,d) global(cr2rc);
    projector=cr2Sym(i(nrow(Q))-Q*Q`);
    call eigen(ew,eu,projector); kept=loc(ew>.5); d=ncol(kept);
    other=j(nrow(Q),1,0);
    if d^=nrow(Q)-ncol(Q) then do; cr2rc='CERTIFICATE_COMPLEMENT_DIMENSION'; return; end;
    if d>0 then do;
      other=eu[,kept];
      if cr2Norm(Q`*other)>2e-8 | cr2Norm(other`*other-i(d))>2e-8 then cr2rc='CERTIFICATE_ORTHOGONALITY';
    end;
  finish;
  start wsSupport(person,p,factorK,flags) global(cr2rc,RunId,FitId,Scope);
    setin &support;
    read point person var {Cluster &_svars} into values;
    read point person var {RunId FitId Scope} into ids;
    if nrow(values)^=1 | ncol(values)^=p+1 | countmiss(values)>0 |
       values[1,1]^=person | nrow(ids)^=1 | ncol(ids)^=3 then do;
      cr2rc='RAW_SUPPORT_ROW_SCHEMA'; return;
    end;
    if ids[1,1]^=RunId | ids[1,2]^=FitId | ids[1,3]^=Scope then do;
      cr2rc='RAW_SUPPORT_CONTEXT'; return;
    end;
    flags=values[,2:(p+1)];
    if any(flags^=0 & flags^=1) then do; cr2rc='RAW_SUPPORT_BOOLEAN'; return; end;
    do column=1 to p;
      if (max(abs(factorK[,column+1]))>0)^=flags[column] then do;
        cr2rc='RAW_SUPPORT_QR_DISAGREEMENT'; return;
      end;
    end;
    setin &wide;
  finish;

start csPhase(label);
  return;
finish;

  boundrc=repeat(' ',1,64); boundrc='NOT_STARTED';
  start csMain(dummy) global(cr2rc,RunId,FitId,Scope,completed,boundrc);
    run csPhase('ENTER');
    run bmHost(0);
    if boundrc^='PASS' then do; cr2rc='BOUND_HOST_REJECTED'; return; end;
    cr2rc='PASS';
    if &_ctxobs^=1 then do; cr2rc='CONTEXT_CARDINALITY'; return; end;
    use &context;
    read all var {RunId} into contextRun; read all var {FitId} into contextFit;
    read all var {Scope} into contextScope; read all var {Tau2 Sigma2 Alpha FittedDesignRank} into target; close &context;
    if nrow(contextRun)^=1 | nrow(contextFit)^=1 | nrow(contextScope)^=1 | nrow(target)^=1 then do;
      cr2rc='CONTEXT_CARDINALITY'; return;
    end;
    RunId=contextRun; FitId=contextFit; Scope=contextScope;
    if (Scope^='SYNTHETIC_DATA_ONLY' & Scope^='LOCAL_SAMPLE_MODEL_INFERENCE' & Scope^='FULL_COHORT_MODEL_INFERENCE') | length(strip(RunId))^=32 | length(strip(FitId))<1 then do;
      cr2rc='CONTEXT_SCOPE'; return;
    end;
    
      use &context; read all var {StatisticKind} into statisticInput; close &context;
      if nrow(statisticInput)^=1 | statisticInput^='AUGMENTED_QR' then do; cr2rc='QR_STATISTIC_KIND'; return; end;
    
    tau2=target[1,1]; sigma2=target[1,2]; alpha=target[1,3];
    if countmiss(target)>0 | tau2<0 | sigma2<=0 | alpha<=0 | alpha>=1 then do;
      cr2rc='WORKING_VARIANCES_OR_ALPHA'; return;
    end;
    p=&_p; k=p+1; blockRows=k+1;
    fittedRank=target[1,4];
    if fittedRank<1 | fittedRank>p | fittedRank^=round(fittedRank) then do;
      cr2rc='WORKING_DESIGN_RANK_INVALID';return;
    end;
    persons=&_obs/blockRows; tiny=constant('SMALL');
    if &_obs^=&_live | persons<2 | persons^=round(persons) then do;
      cr2rc='WIDE_PHYSICAL_CARDINALITY'; return;
    end;
    if &_sobs^=&_slive | &_sobs^=persons then do; cr2rc='RAW_SUPPORT_CARDINALITY'; return; end;
    use &solution; read all var {Parameter Estimate} into bl; close &solution;
    use &contrasts; read all var {Contrast Parameter Weight} into cl; close &contrasts;
    use &span; read all var {Span Parameter Weight} into sl; close &span;
    if countmiss(bl)+countmiss(cl)+countmiss(sl)>0 then do; cr2rc='MISSING_SMALL_MATRIX_INPUT'; return; end;
    if max(cl[,1])<1 | max(cl[,1])>200000 | max(cl[,1])^=round(max(cl[,1])) |
       max(sl[,1])<1 | max(sl[,1])>p | max(sl[,1])^=round(max(sl[,1])) then do;
      cr2rc='SMALL_MATRIX_SIZE_LIMIT'; return;
    end;
    beta=csLong(bl[,1]||j(p,1,1)||bl[,2],p,1); if cr2rc^='PASS' then return;
    C=csLong(cl,max(cl[,1]),p); if cr2rc^='PASS' then return;
    Cspan=csLong(sl,max(sl[,1]),p); if cr2rc^='PASS' then return;
    total=j(p,p,0); totalComp=total; sumScore=j(p,1,0); scoreComp=sumScore; scoreScale=0;
    globalFactor=j(p,p,0); kernelStatus=repeat(' ',1,64);
    supportCount=j(1,p,0); supportOwner=j(1,p,0);
    run csPhase('GLOBAL_GEOMETRY_BEGIN');
    use &support; use &wide;
    do person=1 to persons;
      points=((person-1)*blockRows+1):(person*blockRows);
      read point points var {Cluster Row  NObs  &_xvars Cross} into block;
      run csBlock(block,person,k,rawGram,resCross,factorK,factorResidual); if cr2rc^='PASS' then return;
      
        run csFactorRI(factorK,factorResidual,tau2,sigma2,gram,score,weightedX);
      
      if cr2rc^='PASS' then return;
      run wsSupport(person,p,factorK,flags); if cr2rc^='PASS' then return;
      supportCount=supportCount+flags;
      supported=loc(flags=1); if ncol(supported)>0 then supportOwner[supported]=person;
      run cr2Kahan(total,totalComp,gram); run cr2Kahan(sumScore,scoreComp,score);

        stack=globalFactor//weightedX;
        run rbcUntruncatedQR(stack,globalFactor,kernelStatus);
        if kernelStatus^='PASS' then do; cr2rc='GLOBAL_FACTOR_QR_FAILED'; return; end;
      
      scoreScale=scoreScale+cr2Norm(score);
    end;
    close &wide; close &support;
    run cr2PSD(total,tw,tu); if cr2rc^='PASS' then return;
    if max(tw)<=0 then do; cr2rc='ZERO_DESIGN_RANK'; return; end;
    
      call svd(globalU,globalS,globalV,globalFactor);

      rank=fittedRank;keep=1:rank;
      if min(globalS[keep])<=0 then do;
        cr2rc='WORKING_DESIGN_RANK_UNRESOLVED';return;
      end;
      if rank<p then do;
        if globalS[rank]<=globalS[rank+1] then do;
          cr2rc='WORKING_DESIGN_RANK_AMBIGUOUS';return;
        end;
      end;
      /* Refine only the selected span; preserve the original fitted rank and gap guards. */
      selectedE=globalV[,keep];
      run rbcUntruncatedQR(selectedE,selectedR,kernelStatus);
      if kernelStatus^='PASS' then do; cr2rc='GLOBAL_FACTOR_QR_FAILED'; return; end;
      if nrow(selectedR)^=rank | ncol(selectedR)^=rank then do;
        cr2rc='INVALID_DESIGN_BASIS'; return;
      end;
      selectedQ=solve(selectedR`,selectedE`)`;
      compressedFactor=globalFactor*selectedQ;
      run rbcUntruncatedQR(compressedFactor,refinedR,kernelStatus);
      if kernelStatus^='PASS' then do; cr2rc='GLOBAL_FACTOR_QR_FAILED'; return; end;
      if nrow(refinedR)^=rank | ncol(refinedR)^=rank then do;
        cr2rc='INVALID_DESIGN_BASIS'; return;
      end;
      call svd(refinedU,refinedS,refinedV,refinedR);
      if countmiss(refinedS)>0 | min(refinedS)<=0 then do;
        cr2rc='WORKING_DESIGN_RANK_UNRESOLVED'; return;
      end;
      E=selectedQ*refinedV;
      B=diag(1/(refinedS##2)); Bh=diag(1/refinedS);
      /* Optional retained geometry for the declared fixed-covariance correction.
         These internal matrices are never public result files. */
      %if %symexist(RBC_WEEKDAY_CAPTURE_LIB) %then %do;
        %if %length(%superq(RBC_WEEKDAY_CAPTURE_LIB))>0 %then %do;
          captureBasis=j(p*rank,3,0);capturePos=0;
          do captureR=1 to p;do captureC=1 to rank;
            capturePos=capturePos+1;
            captureBasis[capturePos,]=captureR||captureC||E[captureR,captureC];
          end;end;
          captureGlobal=j(p*p,3,0);capturePos=0;
          do captureR=1 to p;do captureC=1 to p;
            capturePos=capturePos+1;
            captureGlobal[capturePos,]=captureR||captureC||globalFactor[captureR,captureC];
          end;end;
          create &RBC_WEEKDAY_CAPTURE_LIB..capture_globalfactor from captureGlobal[colname={'Row' 'Column' 'Value'}];
            append from captureGlobal;close &RBC_WEEKDAY_CAPTURE_LIB..capture_globalfactor;
          captureBeta=(1:p)`||beta;
          captureParams=tau2||sigma2||rank||p;
          create &RBC_WEEKDAY_CAPTURE_LIB..capture_basis from captureBasis[colname={'Parameter' 'ActiveColumn' 'Value'}];
            append from captureBasis;close &RBC_WEEKDAY_CAPTURE_LIB..capture_basis;
          create &RBC_WEEKDAY_CAPTURE_LIB..capture_beta from captureBeta[colname={'Parameter' 'Estimate'}];
            append from captureBeta;close &RBC_WEEKDAY_CAPTURE_LIB..capture_beta;
          create &RBC_WEEKDAY_CAPTURE_LIB..capture_params from captureParams[colname={'Tau2' 'Sigma2' 'FittedRank' 'ParameterCount'}];
            append from captureParams;close &RBC_WEEKDAY_CAPTURE_LIB..capture_params;
        %end;
      %end;

    
    if cr2Norm(E`*sumScore)>2e-8*max(scoreScale,tiny) then do; cr2rc='SCORES_NOT_FROM_FITTED_GLS'; return; end;
    transform=j(k,rank+1,0); transform[1,1]=1; transform[2:k,2:(rank+1)]=E;
    do tr=1 to nrow(Cspan);
      if cr2Norm(Cspan[tr,]-Cspan[tr,]*E*E`)>2e-8*cr2Norm(Cspan[tr,]) then do;
        cr2rc='NONESTIMABLE_CONTRAST'; return;
      end;
    end;
    run cr2Normalize(E,B,Cspan,Cnorm,N,rowScales); if cr2rc^='PASS' then return;
    h=nrow(Cspan); dim=h*(h+1)/2; dr=rank*(rank+1)/2;
    if 8*(4*dim*dr+6*dim*dim)>512*2##20 then do; cr2rc='MOMENT_ARCHIVE_SIZE_LIMIT'; return; end;
    momentT=B*Cnorm`; pairH=cr2Pairs(h); pairR=cr2Pairs(rank);
     
    if 8*(12*dim*dr+32*dim*dim)+64*2##20>2048*2##20 then do;
      cr2rc='BOUND_WORKSPACE_SIZE_LIMIT'; return;
    end;
    Ksum=j(dim,dr,0); Kcomp=Ksum; Msum=j(dim,dim,0); Mcomp=Msum;
    boundMsumError=j(dim,dim,0); boundCorrectionError=boundMsumError;
    boundKsumError=j(dim,dr,0);
    BoundDiagonalExact=1; BoundKiExact=1; BoundRemoveExact=1;
    BoundRecenteringFinite=0;
    correction=Msum; correctionComp=Msum; reference=j(h,h,0); normBudget=0;
    meat=j(rank,rank,0); meatComp=meat; maxLeverage=0; maxRootError=0; maxRootSteps=0;
    minLocalRank=rank+1; maxLocalRank=0; processed=0;
    run csPhase('CLUSTER_CERTIFICATE_BEGIN'); phaseHeartbeat=datetime();
    certifiedClusters=0; maxCertifiedNullity=0; identityP=i(p); Bih=diag(1/vecdiag(Bh));
    use &wide;
    do person=1 to persons;
      if datetime()-phaseHeartbeat>=30 then do;
        run csPhase('CLUSTER_CERTIFICATE_HEARTBEAT');phaseHeartbeat=datetime();
      end;
      points=((person-1)*blockRows+1):(person*blockRows);
      read point points var {Cluster Row  NObs  &_xvars Cross} into block;
      run csBlock(block,person,k,rawGram,resCross,factorK,factorResidual); if cr2rc^='PASS' then return;
      
        run csFactorRI(factorK,factorResidual,tau2,sigma2,gram,score,weightedX);
      
      if cr2rc^='PASS' then return;
      activeScore=E`*score;
      
        activeWeighted=weightedX*E; activeGram=cr2Sym(activeWeighted`*activeWeighted);
      
      if cr2Norm(score-E*activeScore)>2e-8*max(cr2Norm(score),tiny) then do; cr2rc='SCORE_OUTSIDE_DESIGN_SPACE'; return; end;
      normalizedX=activeWeighted*Bh;
      call svd(hu,hs,hv,normalizedX); leverage=max(hs)##2;
      maxLeverage=max(maxLeverage,leverage); certificateDim=0;
      if leverage>=1-1e-10 then do;
        literal=loc(supportCount=1 & supportOwner=person);
        if ncol(literal)=0 then do; cr2rc='STRUCTURAL_NULLSPACE_UNCERTIFIED'; return; end;
        rawN=identityP[,literal]; activeN=E`*rawN;
        projectionError=cr2Norm(globalFactor*(rawN-E*activeN));
        projectionScale=cr2Norm(globalFactor*rawN);
        if projectionError>128*constant('MACEPS')*max(p,blockRows)*max(projectionScale,tiny) then do;
          cr2rc='LITERAL_CERTIFICATE_PROJECTION'; return;
        end;
        run wsOrth(Bih*activeN,certificate,certificateDim);
        if certificateDim<1 then do; cr2rc='EMPTY_STRUCTURAL_CERTIFICATE'; return; end;

        if cr2Norm(normalizedX`*normalizedX*certificate-certificate)>2e-8 then do;
          cr2rc='STRUCTURAL_CERTIFICATE_NOT_NULL'; return;
        end;
        targetLeak=Cnorm*Bh*certificate;
        do tr=1 to nrow(Cnorm);
          if cr2Norm(targetLeak[tr,])>2e-8 then do;
            cr2rc='PLANNED_TARGET_NOT_LOO_ESTIMABLE'; return;
          end;
        end;
        run wsComplement(certificate,remaining,remainingDim); if cr2rc^='PASS' then return;
        if remainingDim>0 then do;
          call svd(ru,rs,rv,normalizedX*remaining);
          if max(rs)##2>=1-1e-10 then do;
            cr2rc='UNCERTIFIED_REMAINING_SATURATION'; return;
          end;
        end;
        certifiedClusters=certifiedClusters+1;
        maxCertifiedNullity=max(maxCertifiedNullity,certificateDim);
      end;
      
        localFactor=factorK*transform;
        call svd(su,sv,svv,localFactor);
        cutoff=32*constant('MACEPS')*max(nrow(localFactor),ncol(localFactor))*max(sv);
        keep=loc(sv>cutoff);
        if ncol(keep)=0 then do; cr2rc='ZERO_LOCAL_QR_SPAN'; return; end;
        eig=sv[keep]; Rall=su[,keep]`*localFactor; er=su[,keep]`*factorResidual;
      
      q1=Rall[,1]; projectX=Rall[,2:(rank+1)];
      V=sigma2*i(nrow(eig))+tau2*q1*q1`; weight=cr2Power(V,-1); if cr2rc^='PASS' then return;
      Vih=cr2Power(V,-.5); if cr2rc^='PASS' then return;
      whiteX=Vih*projectX; whiteResidual=Vih*er;
      whiteS=cr2Sym(i(nrow(eig))-whiteX*B*whiteX`);
      targetProjector=i(nrow(eig)); steps=0;
      if certificateDim>0 then do;
        run wsOrth(whiteX*Bh*certificate,localNull,localNullDim);
        if localNullDim^=certificateDim then do; cr2rc='LOCAL_CERTIFICATE_RANK'; return; end;
        if cr2Norm(whiteS*localNull)>2e-8 then do; cr2rc='LOCAL_CERTIFICATE_NOT_NULL'; return; end;

        
        nativeScaleQ1=factorK[,1]; nativeScaleN=ssq(nativeScaleQ1);
        nativeScaleResidualSum=nativeScaleQ1`*factorResidual;
        nativeScaleResidual=(factorResidual-nativeScaleQ1*nativeScaleResidualSum/nativeScaleN)/sqrt(sigma2)
          +nativeScaleQ1*nativeScaleResidualSum/(nativeScaleN*sqrt(sigma2+nativeScaleN*tau2));
        residualScale=cr2Norm(nativeScaleResidual)+cr2Norm(activeWeighted*(E`*beta));
        if cr2Norm(localNull`*whiteResidual)>2e-8*max(residualScale,tiny) then do;
          cr2rc='EXCLUSIVE_NATIVE_RESIDUAL_MISMATCH'; return;
        end;
        targetProjector=cr2Sym(targetProjector-localNull*localNull`);
        run wsComplement(localNull,positive,positiveDim); if cr2rc^='PASS' then return;
        A=j(nrow(eig),nrow(eig),0);
        if positiveDim>0 then do;
          inverseRoot=cr2Power(positive`*whiteS*positive,-.5); if cr2rc^='PASS' then return;
          A=cr2Sym(positive*inverseRoot*positive`);
        end;
      end;
      else do; A=cr2Power(whiteS,-.5); if cr2rc^='PASS' then return; end;
      rootError=cr2Norm(A*whiteS*A-targetProjector);
      if rootError>2e-8 then do; cr2rc='WHITENED_ROOT_IDENTITY_FAILED'; return; end;
      if max(abs(projectX`*weight*er-activeScore)-2e-8*abs(activeScore))>1e-10 then do; cr2rc='PROJECTED_SCORE_MISMATCH'; return; end;
      targetMap=Cnorm*B*whiteX`;
      calibrated=cr2Sym(targetMap*A*whiteS*A*targetMap`);
      expected=cr2Sym(momentT`*activeGram*momentT);
      if cr2Norm(calibrated-expected)>2e-8 then do; cr2rc='TARGET_SPAN_CALIBRATION_FAILED'; return; end;
      adjusted=whiteX`*A*whiteResidual; adjustment=whiteX`*A*whiteX;
      run cr2Kahan(meat,meatComp,adjusted*adjusted`);
      Hii=cr2Sym(momentT`*activeGram*momentT); Li=momentT`*adjustment*Bh;
      reference=reference+Hii; Ki=cr2SymSquarePairs(Li,pairH,pairR);
      diagonal=cr2SymSquarePairs(Hii,pairH,pairH); remove=cr2SymSquarePairs(Li*Li`,pairH,pairH);
      zeroH=j(h,h,0); zeroL=j(h,rank,0);
      run bmSquare(Hii,zeroH,pairH,pairH,boundDiagonal,boundDiagonalError);
      run bmSquare(Li,zeroL,pairH,pairR,boundKi,boundKiError);
      run bmDot(Li,zeroL,Li`,zeroL`,boundU,boundUError);
      run bmSquare(boundU,boundUError,pairH,pairH,boundRemove,boundRemoveError);
      if boundrc^='PASS' then do; cr2rc='BOUND_CONSTRUCTION_FAILED'; return; end;
      shiftedDiagonalError=bmRecenter(diagonal,boundDiagonal,boundDiagonalError);
      shiftedKiError=bmRecenter(Ki,boundKi,boundKiError);
      shiftedRemoveError=bmRecenter(remove,boundRemove,boundRemoveError);
      if boundrc^='PASS' then do; cr2rc='BOUND_RECENTER_FAILED'; return; end;
      BoundDiagonalExact=BoundDiagonalExact & (max(abs(diagonal-boundDiagonal))=0);
      BoundKiExact=BoundKiExact & (max(abs(Ki-boundKi))=0);
      BoundRemoveExact=BoundRemoveExact & (max(abs(remove-boundRemove))=0);
       
      run bmKahan(Msum,Mcomp,diagonal,shiftedDiagonalError,boundMsumError);
      run bmKahan(correction,correctionComp,remove,shiftedRemoveError,boundCorrectionError);
      run bmKahan(Ksum,Kcomp,Ki,shiftedKiError,boundKsumError);
      normBudget=normBudget+cr2Norm(diagonal)+cr2Norm(remove);
      maxRootError=max(maxRootError,rootError); maxRootSteps=max(maxRootSteps,steps);
      minLocalRank=min(minLocalRank,nrow(eig)); maxLocalRank=max(maxLocalRank,nrow(eig)); processed=processed+1;
    end;
    close &wide;
    run csPhase('CLUSTER_CERTIFICATE_END');
    if processed^=persons then do; cr2rc='INCOMPLETE_CLUSTER_PASS'; return; end;
    if max(abs(reference-i(h))-2e-8*abs(i(h)))>1e-9 then do; cr2rc='REFERENCE_EXPECTATION_NOT_IDENTITY'; return; end;
    allPairs=Ksum*Ksum`; M=cr2Sym(Msum+allPairs-correction); normBudget=normBudget+cr2Norm(allPairs);
    envelope=constant('MACEPS')*(64+8*persons)*normBudget;
    boundMsumError=bmKahanError(Msum,boundMsumError);
    boundCorrectionError=bmKahanError(correction,boundCorrectionError);
    boundKsumError=bmKahanError(Ksum,boundKsumError);
     
    run bmFinish(Msum,boundMsumError,Ksum,boundKsumError,correction,boundCorrectionError,
                 boundMomentCentral,boundMomentError);
    BoundCentralMomentEqual=(max(abs(M-boundMomentCentral))=0);
    reportedMomentError=bmRecenter(M,boundMomentCentral,boundMomentError);
    if boundrc^='PASS' then do; cr2rc='BOUND_FINAL_RECENTER_FAILED'; return; end;
    BoundRecenteringFinite=1;

    run csPhase('FINAL_MOMENT_END');
    call eigen(mw,mu,M);
    if min(mw)<-envelope then do; cr2rc='NON_PSD_GAUSSIAN_MOMENT'; return; end;
    activeCov=cr2Sym(B*meat*B); cov=cr2Sym(E*activeCov*E`);
    Vnorm=cr2Sym(Cnorm*activeCov*Cnorm`); contrastBasis=Cnorm*E`;
    call svd(spanU,spanS,spanV,Cnorm`);
    if min(spanS)<=1e-6*max(spanS) then do; cr2rc='ILL_CONDITIONED_SCORE_SPAN'; return; end;
    rightInverse=spanU*diag(1/spanS)*spanV`;
    weights=C*E*rightInverse; codes=j(nrow(C),1,0);
    do ci=1 to nrow(C);
      cn=cr2Norm(C[ci,]);
      if cn=0 then codes[ci]=2;
      else if cr2Norm(C[ci,]-C[ci,]*E*E`)>2e-8*cn then codes[ci]=1;
      else if cr2Norm(C[ci,]-weights[ci,]*contrastBasis)>2e-8*cn then codes[ci]=5;
      if codes[ci]^=0 then weights[ci,]=0;
    end;
    run csPhase('SCALAR_CERTIFICATE_BEGIN');
    run cr2CertifiedScalar(weights,i(h),M,Vnorm,reportedMomentError,
                           scalar,scalarCertificate,nativeWeights);
    if cr2rc^='PASS' | boundrc^='PASS' then do;
      if cr2rc='PASS' then cr2rc='BOUND_SCALAR_CERTIFICATE_FAILED';
      return;
    end;
    run csPhase('SCALAR_CERTIFICATE_END');
    inference=j(nrow(C),12,.);
    do ci=1 to nrow(C);
      status=scalar[ci,2]; if codes[ci]^=0 then status=codes[ci];
      inference[ci,1:2]=ci||status;
      if status=0 then do;
        variance=scalar[ci,4];
        if variance<=0 then inference[ci,2]=3;
        else do;
          df=scalar[ci,3];
          if df=. | df<1-1e-8 | df>persons*(1+1e-8) then do;
            cr2rc='DF_REFERENCE_BOUNDS'; return;
          end;
          estimate=C[ci,]*beta; se=sqrt(variance); t=estimate/se;
          prob=2*cdf('T',-abs(t),df); critical=tinv(1-alpha/2,df);
          inference[ci,3:12]=estimate||se||df||t||prob||(estimate-critical*se)||(estimate+critical*se)||variance||scalar[ci,5]||.;
        end;
      end;
    end;

    covLong=j(p*p,3,0); basisLong=j(p*rank,3,0); breadLong=j(rank*rank,3,0);
    pos=0; do rr=1 to p; do cc=1 to p; pos=pos+1; covLong[pos,]=rr||cc||cov[rr,cc]; end; end;
    pos=0; do rr=1 to p; do cc=1 to rank; pos=pos+1; basisLong[pos,]=rr||cc||E[rr,cc]; end; end;
    pos=0; do rr=1 to rank; do cc=1 to rank; pos=pos+1; breadLong[pos,]=rr||cc||B[rr,cc]; end; end;
    create &outlib..&prefix._covariance from covLong[colname={'Row' 'Col' 'Value'}]; append from covLong; close &outlib..&prefix._covariance;
    create &outlib..&prefix._basis from basisLong[colname={'Parameter' 'ActiveColumn' 'Value'}]; append from basisLong; close &outlib..&prefix._basis;
    create &outlib..&prefix._bread from breadLong[colname={'Row' 'Col' 'Value'}]; append from breadLong; close &outlib..&prefix._bread;
    create &outlib..&prefix._moment from M; append from M; close &outlib..&prefix._moment;
    create &outlib..&prefix._spanbasis from contrastBasis; append from contrastBasis; close &outlib..&prefix._spanbasis;
    create &outlib..&prefix._spanrobust from Vnorm; append from Vnorm; close &outlib..&prefix._spanrobust;
    create &outlib..&prefix._inference from inference[colname={'Contrast' 'ContrastStatus' 'Estimate' 'StdErr' 'DF' 'tValue' 'Probt' 'Lower' 'Upper' 'Variance' 'ReferenceVariance' 'MaxReferenceShare'}]; append from inference; close &outlib..&prefix._inference;
    create &outlib..&prefix._solution from bl[colname={'Parameter' 'Estimate'}]; append from bl; close &outlib..&prefix._solution;
    rootSummary=processed||minLocalRank||maxLocalRank||maxRootError||maxRootSteps||maxLeverage;
    create &outlib..&prefix._root_summary from rootSummary[colname={'ClustersProcessed' 'MinLocalRank' 'MaxLocalRank' 'MaxRootError' 'MaxRootIterations' 'MaxLeverage'}]; append from rootSummary; close &outlib..&prefix._root_summary;
    StatisticKind='AUGMENTED_QR';
    DesignRank=rank; ParameterCount=p; ClusterCount=persons; SpanDimension=h; MomentDimension=dim; RoundoffEnvelope=envelope;
    CovarianceMethod='GLS_WHITENED_CR2'; CalibrationDomain='FIXED_PREDECLARED_TARGET_SPAN';
    StructuralCertificate='RAW_LITERAL_SUPPORT_V1'; TargetCalibrationVerified=1;
    AllCoefficientsCalibrated=0;
    create &outlib..&prefix._context var {RunId FitId Scope Tau2 Sigma2 Alpha DesignRank ParameterCount ClusterCount SpanDimension MomentDimension RoundoffEnvelope StatisticKind CovarianceMethod CalibrationDomain StructuralCertificate TargetCalibrationVerified AllCoefficientsCalibrated CertifiedClusters MaxCertifiedNullity}; append; close &outlib..&prefix._context;
    create &outlib..&prefix._moment_error from reportedMomentError;
      append from reportedMomentError; close &outlib..&prefix._moment_error;
    nativeWeightTable=(1:nrow(nativeWeights))`||nativeWeights;
    weightNames='TargetIndex'||('COL'+strip(char(1:h)));
    create &outlib..&prefix._scalar_weights from nativeWeightTable[colname=weightNames];
      append from nativeWeightTable;close &outlib..&prefix._scalar_weights;
    create &outlib..&prefix._scalar_certificate from scalarCertificate[
      colname={'TargetIndex' 'Denominator' 'AbsError' 'RelativeErrorUpper'
               'IdealRelativeErrorUpper' 'Resolved'}];
      append from scalarCertificate;close &outlib..&prefix._scalar_certificate;
    run csPhase('ARCHIVE_WRITTEN');
    completed=1;
  finish;
  dummy=0; run csMain(dummy);
  if completed^=1 & cr2rc='PASS' then cr2rc='NOT_COMPLETED';
  create &outlib..&prefix._status var {RunId FitId Scope cr2rc}; append; close &outlib..&prefix._status;
quit;
options &_rbc_iml_cpu;
%mend;

%macro rbc_qr_iml_modules;
   
  start rbcPairwiseSSQ(vector);
    terms=vector#vector;
    termCount=nrow(terms);
    do while(termCount>1);
      pairCount=floor(termCount/2);
      left=2*T(1:pairCount)-1;
      right=left+1;
      combined=terms[left]+terms[right];
      if mod(termCount,2)=1 then combined=combined//terms[termCount];
      terms=combined;
      termCount=nrow(terms);
    end;
    return(terms[1]);
  finish;

  start rbcPairwiseDot(vector, matrix);
    terms=matrix#repeat(vector,1,ncol(matrix));
    termCount=nrow(terms);
    do while(termCount>1);
      pairCount=floor(termCount/2);
      left=2*T(1:pairCount)-1;
      right=left+1;
      combined=terms[left,]+terms[right,];
      if mod(termCount,2)=1 then combined=combined//terms[termCount,];
      terms=combined;
      termCount=nrow(terms);
    end;
    return(terms[1,]);
  finish;
  start rbcUntruncatedQR(inputMatrix, factorMatrix, kernelStatus);
    kernelStatus='PASS';
    if nrow(inputMatrix)<1 | ncol(inputMatrix)<1 | countmiss(inputMatrix)>0 then do;
      kernelStatus='QR_INPUT_INVALID'; return;
    end;
    transformed=inputMatrix;
    rowCount=nrow(transformed); columnCount=ncol(transformed);
    do columnIndex=1 to min(rowCount,columnCount);
      direction=transformed[columnIndex:rowCount,columnIndex];
      columnScale=max(abs(direction));
      if columnScale>0 then do;
        direction=direction/columnScale;
        directionNorm=sqrt(rbcPairwiseSSQ(direction));
        signChoice=1; if direction[1]<0 then signChoice=-1;
        direction[1]=direction[1]+signChoice*directionNorm;
        reflectorNorm=sqrt(rbcPairwiseSSQ(direction));
        if reflectorNorm<=0 | nmiss(reflectorNorm)>0 then do;
          kernelStatus='QR_REFLECTOR_INVALID'; return;
        end;
        direction=direction/reflectorNorm;
        submatrix=transformed[columnIndex:rowCount,columnIndex:columnCount];
        submatrix=submatrix-2*direction*(rbcPairwiseDot(direction,submatrix));
        transformed[columnIndex:rowCount,columnIndex:columnCount]=submatrix;
        transformed[columnIndex,columnIndex]=-signChoice*directionNorm*columnScale;
        if columnIndex<rowCount then transformed[columnIndex+1:rowCount,columnIndex]=0;
      end;
    end;
    factorMatrix=transformed[1:min(rowCount,columnCount),];
    if countmiss(factorMatrix)>0 then kernelStatus='QR_OUTPUT_INVALID';
  finish;
%mend;

%macro rbc_cluster_qr_reject(reason=);
    %global RBC_CLUSTER_QR_OK RBC_CLUSTER_QR_REASON;
    %let RBC_CLUSTER_QR_OK=0;
    %let RBC_CLUSTER_QR_REASON=&reason;
    %put NOTE: RBC_CLUSTER_QR_STATUS &reason;
%mend;

%macro rbc_prepare_cluster_qr(design=,solution=,outlib=WORK,prefix=cs,
        parameter_count=,expected_rows=,expected_persons=,
        run_id=,fit_id=,scope=SYNTHETIC_DATA_ONLY,chunk_rows=8192,support=NO);
    %local p k names i rc dsid bad badmatrix nrows nperson nbeta nuniq minidx maxidx member members;
    %global RBC_CLUSTER_QR_OK RBC_CLUSTER_QR_REASON;
    %let RBC_CLUSTER_QR_OK=0; %let RBC_CLUSTER_QR_REASON=NOT_COMPLETED;
    %if %superq(support) ne NO and %superq(support) ne YES %then %do;
        %rbc_cluster_qr_reject(reason=INVALID_SUPPORT_POLICY); %return;
    %end;
    %if %superq(scope) ne SYNTHETIC_DATA_ONLY and %superq(scope) ne LOCAL_SAMPLE_MODEL_INFERENCE and %superq(scope) ne FULL_COHORT_MODEL_INFERENCE %then %do;
        %rbc_cluster_qr_reject(reason=INFERENCE_SCOPE_INVALID); %return;
    %end;
    %if %length(%superq(prefix))=0 or %length(%superq(prefix))>12 or
        %length(%superq(outlib))=0 or %length(%superq(outlib))>8 %then %do;
        %rbc_cluster_qr_reject(reason=INVALID_NAMES); %return;
    %end;
    %if not %sysfunc(nvalid(&prefix,V7)) or not %sysfunc(nvalid(&outlib,V7)) %then %do;
        %rbc_cluster_qr_reject(reason=INVALID_NAMES); %return;
    %end;
    %if %sysfunc(libref(&outlib)) ne 0 %then %do;
        %rbc_cluster_qr_reject(reason=UNASSIGNED_LIBRARY); %return;
    %end;
    %if %sysfunc(prxmatch(%str(/^[1-9][0-9]*$/),%superq(parameter_count))) ne 1 or
        %sysfunc(prxmatch(%str(/^[1-9][0-9]*$/),%superq(expected_rows))) ne 1 or
        %sysfunc(prxmatch(%str(/^[1-9][0-9]*$/),%superq(expected_persons))) ne 1 %then %do;
        %rbc_cluster_qr_reject(reason=INVALID_DIMENSIONS); %return;
    %end;
    %if %sysfunc(prxmatch(%str(/^[1-9][0-9]*$/),%superq(chunk_rows))) ne 1 %then %do;
        %rbc_cluster_qr_reject(reason=INVALID_CHUNK_SIZE); %return;
    %end;
    %if &chunk_rows>65536 %then %do;
        %rbc_cluster_qr_reject(reason=INVALID_CHUNK_SIZE); %return;
    %end;
    %let p=&parameter_count; %let k=%eval(&p+2);
    %if &p>200 %then %do;
        %rbc_cluster_qr_reject(reason=PARAMETER_LIMIT); %return;
    %end;
    %if %sysfunc(prxmatch(%str(/^[0-9a-f]{32}$/),%superq(run_id))) ne 1 or
        %sysfunc(prxmatch(%str(/^[A-Za-z0-9_-]{1,128}$/),%superq(fit_id))) ne 1 %then %do;
        %rbc_cluster_qr_reject(reason=INVALID_CONTEXT); %return;
    %end;
    %let members=qr solution context status;
    %if &support=YES %then %let members=&members support;
    %do i=1 %to %sysfunc(countw(&members));
        %let member=%scan(&members,&i);
        %if %sysfunc(exist(&outlib..&prefix._&member)) or %sysfunc(exist(&outlib..&prefix._&member,VIEW)) %then %do;
            %rbc_cluster_qr_reject(reason=TARGET_EXISTS); %return;
        %end;
    %end;
    %do i=1 %to 6;
        %let member=%scan(_rqr_beta _rqr_real _rqr_sorted _rqr_rows _rqr_index _rqr_meta,&i);
        %if %sysfunc(exist(work.&member)) %then %do;
            %rbc_cluster_qr_reject(reason=SCRATCH_EXISTS); %return;
        %end;
    %end;
    %let names=;
    %do i=1 %to &p; %let names=&names RBCX&i; %end;
    %let dsid=%sysfunc(open(&design,i));
    %if &dsid=0 %then %do;
        %rbc_cluster_qr_reject(reason=DESIGN_MISSING); %return;
    %end;
    %let bad=0;
    %do i=1 %to %eval(&p+2);
        %let member=%scan(PatientID Value &names,&i);
        %let rc=%sysfunc(varnum(&dsid,&member));
        %if &rc=0 %then %let bad=1;
        %else %if %sysfunc(vartype(&dsid,&rc)) ne N %then %let bad=1;
    %end;
    %let rc=%sysfunc(varnum(&dsid,RBC_Source));
    %if &rc=0 %then %let bad=1;
    %else %if %sysfunc(vartype(&dsid,&rc)) ne C %then %let bad=1;
    %let rc=%sysfunc(close(&dsid));
    %if &bad %then %do;
        %rbc_cluster_qr_reject(reason=DESIGN_SCHEMA); %return;
    %end;
    %let dsid=%sysfunc(open(&solution,i));
    %if &dsid=0 %then %do;
        %rbc_cluster_qr_reject(reason=SOLUTION_MISSING); %return;
    %end;
    %let rc=%sysfunc(varnum(&dsid,Effect)); %let bad=0;
    %if &rc=0 %then %let bad=1;
    %else %if %sysfunc(vartype(&dsid,&rc)) ne C %then %let bad=1;
    %let rc=%sysfunc(varnum(&dsid,Estimate));
    %if &rc=0 %then %let bad=1;
    %else %if %sysfunc(vartype(&dsid,&rc)) ne N %then %let bad=1;
    %let rc=%sysfunc(close(&dsid));
    %if &bad %then %do;
        %rbc_cluster_qr_reject(reason=SOLUTION_SCHEMA); %return;
    %end;
    data work._rqr_beta;
        set &solution(keep=Effect Estimate);
        Parameter=input(substr(strip(Effect),5),?? best32.);
        if prxmatch('/^RBCX[1-9][0-9]*$/i',strip(Effect)) ne 1
           or missing(Estimate) then call symputx('bad',1,'L');
        keep Parameter Estimate;
    run;
    proc sql noprint;
        select count(*),count(distinct Parameter),min(Parameter),max(Parameter)
        into :nbeta trimmed,:nuniq trimmed,:minidx trimmed,:maxidx trimmed
        from work._rqr_beta;
    quit;
    %if &bad or &nbeta ne &p or &nuniq ne &p or &minidx ne 1 or &maxidx ne &p %then %do;
        %rbc_cluster_qr_reject(reason=SOLUTION_INDEX); %goto cleanup;
    %end;
    data work._rqr_real;
        array b[&p] _temporary_;
        if _n_=1 then do j=1 to &p;
            set work._rqr_beta;
            b[Parameter]=Estimate;
        end;
        set &design(where=(RBC_Source='REAL') keep=PatientID Value RBC_Source &names);
        array x[&p] &names;
        if nmiss(PatientID,Value,of x[*])>0 then call symputx('bad',1,'L');

        fitted=0;
        do j=1 to &p; fitted=fitted+x[j]*b[j]; end;
        RBCResidual=Value-fitted;
        if missing(RBCResidual) then call symputx('bad',1,'L');
        keep PatientID RBCResidual &names;
    run;
    proc sql noprint;
        select count(*),count(distinct PatientID) into :nrows trimmed,:nperson trimmed
        from work._rqr_real;
    quit;
    %if &bad or &nrows ne &expected_rows or &nperson ne &expected_persons %then %do;
        %rbc_cluster_qr_reject(reason=DESIGN_ROWS_OR_MISSING); %goto cleanup;
    %end;
    proc sort data=work._rqr_real out=work._rqr_sorted;
        by PatientID;
    run;

    data work._rqr_rows(keep=Cluster K0 &names RBCResidual)
         work._rqr_index(keep=Cluster FirstRow LastRow NObs);
        set work._rqr_sorted;
        by PatientID;
        retain Cluster 0 FirstRow;
        if first.PatientID then do; Cluster+1; FirstRow=_n_; end;
        K0=1; output work._rqr_rows;
        if last.PatientID then do;
            LastRow=_n_; NObs=LastRow-FirstRow+1;
            output work._rqr_index;
        end;
    run;
    data &outlib..&prefix._solution; set work._rqr_beta; run;
     
    proc datasets library=work nolist; delete _rqr_beta _rqr_real _rqr_sorted; quit;
    proc iml;
      %rbc_qr_iml_modules;
      qrstatus='PASS'; maxRowsInCore=0; totalChunks=0;
      start buildQR(dummyArg) global(qrstatus,maxRowsInCore,totalChunks);
        use work._rqr_index;
          read all var {Cluster FirstRow LastRow NObs} into ranges;
        close work._rqr_index;
        if nrow(ranges)^=&expected_persons | countmiss(ranges)>0 then do;
          qrstatus='CLUSTER_INDEX_INVALID'; return;
        end;
        if any(ranges[,1]^=T(1:nrow(ranges))) |
           any(ranges[,4]^=ranges[,3]-ranges[,2]+1) |
           sum(ranges[,4])^=&expected_rows then do;
          qrstatus='CLUSTER_INDEX_INVALID'; return;
        end;
        qsize=&k;
        cnames={'Cluster' 'Row' 'NObs' 'K0'
          %do i=1 %to &p; "RBCX&i" %end; 'Cross'};
        outblock=j(1,qsize+3,0);
        create &outlib..&prefix._qr from outblock[colname=cnames];
        %if &support=YES %then %do;
          supportBlock=j(1,&p+1,0);
          supportNames={'Cluster' %do i=1 %to &p; "HasX&i" %end;};
          create &outlib..&prefix._support from supportBlock[colname=supportNames];
        %end;
        use work._rqr_rows;
        do clusterIndex=1 to nrow(ranges);
          rfactor=j(qsize,qsize,0);
          %if &support=YES %then %do; rawSupport=j(1,&p,0); %end;
          firstPoint=ranges[clusterIndex,2]; lastPoint=ranges[clusterIndex,3];
          processed=0;
          do while(firstPoint<=lastPoint);
            lastInChunk=min(lastPoint,firstPoint+&chunk_rows-1);
            points=firstPoint:lastInChunk;
            setin work._rqr_rows;
            read point points var {K0 &names RBCResidual} into chunk;
            if nrow(chunk)^=ncol(points) | countmiss(chunk)>0 then do;
              qrstatus='CHUNK_READ_INVALID'; return;
            end;

            %if &support=YES %then %do;
              chunkNonzero=(chunk[,2:(&p+1)]^=0);
              rawSupport=(rawSupport | chunkNonzero[<>,]);
            %end;
            stacked=rfactor//chunk;
            maxRowsInCore=max(maxRowsInCore,nrow(stacked));
            totalChunks=totalChunks+1;

            run rbcUntruncatedQR(stacked,rfactor,kernelStatus);
            if kernelStatus^='PASS' | nrow(rfactor)^=qsize | ncol(rfactor)^=qsize |
               countmiss(rfactor)>0 then do;
              qrstatus='QR_KERNEL_INVALID'; return;
            end;
            processed=processed+nrow(chunk);
            firstPoint=lastInChunk+1;
          end;
          if processed^=ranges[clusterIndex,4] |
             abs(ssq(rfactor[,1])-processed)>256*constant('maceps')*processed then do;
            qrstatus='QR_COUNT_IDENTITY_FAILED'; return;
          end;
          outblock=j(qsize,1,clusterIndex)||T(1:qsize)||
                   j(qsize,1,processed)||rfactor;
          setout &outlib..&prefix._qr; append from outblock;
          %if &support=YES %then %do;
            supportBlock=clusterIndex||rawSupport;
            setout &outlib..&prefix._support; append from supportBlock;
          %end;
        end;
        close work._rqr_rows; close &outlib..&prefix._qr;
        %if &support=YES %then %do; close &outlib..&prefix._support; %end;
      finish;
      dummyArg=0; run buildQR(dummyArg);
      create work._rqr_meta var {qrstatus maxRowsInCore totalChunks};
        append; close work._rqr_meta;
    quit;
    %if &syserr ne 0 or &syscc ne 0 %then %do;
        %rbc_cluster_qr_reject(reason=QR_PROCEDURE_FAILED); %goto cleanup;
    %end;
    data &outlib..&prefix._status;
        length RunId $32 FitId $128 Scope $32;
        set work._rqr_meta;
        RunId="&run_id"; FitId="&fit_id"; Scope="&scope";
        if qrstatus ne 'PASS' then call symputx('bad',1,'L');
    run;
    %if &bad %then %do;
        %rbc_cluster_qr_reject(reason=QR_NUMERICAL_GUARD_FAILED); %goto cleanup;
    %end;
    %if &support=YES %then %do;
      data &outlib..&prefix._support;
        length RunId $32 FitId $128 Scope $32;
        set &outlib..&prefix._support;
        RunId="&run_id"; FitId="&fit_id"; Scope="&scope";
      run;
    %end;
    data &outlib..&prefix._context;
        length RunId $32 FitId $128 Scope $32 Method $64 StatisticKind $32;
        RunId="&run_id"; FitId="&fit_id"; Scope="&scope";
        Method='BOUNDED_HOUSEHOLDER_QR_NO_RANK_TRUNCATION'; StatisticKind='AUGMENTED_QR';
        ParameterCount=&p; FactorRows=&k;
        ClusterCount=&expected_persons; ObservationCount=&expected_rows;
        ChunkRows=&chunk_rows;
    run;
    %if &syserr=0 and &syscc=0 %then %do;
        %let RBC_CLUSTER_QR_OK=1; %let RBC_CLUSTER_QR_REASON=PASS;
    %end;
    %cleanup:
    proc datasets library=work nolist;
        delete _rqr_beta _rqr_real _rqr_sorted _rqr_rows _rqr_index _rqr_meta;
    quit;
%mend;

%macro rbc_iu_schema(data=,chars=,nums=);
    %local dsid i variable position rc;
    %let dsid=%sysfunc(open(&data,i));
    %if &dsid=0 %then %do;
        %let RBC_ARCHIVE_REASON=INPUT_SCHEMA_INVALID;
        %return;
    %end;
    %if %length(%superq(chars))>0 %then %do;
    %do i=1 %to %sysfunc(countw(&chars));
        %let variable=%scan(&chars,&i);
        %let position=%sysfunc(varnum(&dsid,&variable));
        %if &position=0 %then %let RBC_ARCHIVE_REASON=INPUT_SCHEMA_INVALID;
        %else %if %sysfunc(vartype(&dsid,&position)) ne C %then
            %let RBC_ARCHIVE_REASON=INPUT_SCHEMA_INVALID;
    %end;
    %end;
    %if %length(%superq(nums))>0 %then %do;
    %do i=1 %to %sysfunc(countw(&nums));
        %let variable=%scan(&nums,&i);
        %let position=%sysfunc(varnum(&dsid,&variable));
        %if &position=0 %then %let RBC_ARCHIVE_REASON=INPUT_SCHEMA_INVALID;
        %else %if %sysfunc(vartype(&dsid,&position)) ne N %then
            %let RBC_ARCHIVE_REASON=INPUT_SCHEMA_INVALID;
    %end;
    %end;
    %let rc=%sysfunc(close(&dsid));
%mend;

%macro rbc_iu_reject(reason=);
  %global RBC_IU_OK RBC_IU_REASON;
  %let RBC_IU_OK=0; %let RBC_IU_REASON=&reason;
  %put NOTE: RBC_CR2_INFERENCE_UNAVAILABLE_STATUS &reason;
%mend;
%macro rbc_iu_export_reject(reason=);
  %global RBC_IU_EXPORT_OK RBC_IU_EXPORT_REASON;
  %let RBC_IU_EXPORT_OK=0; %let RBC_IU_EXPORT_REASON=&reason;
  %put NOTE: RBC_CR2_INFERENCE_UNAVAILABLE_EXPORT &reason;
%mend;
 
%macro rbc_iu_scratch_clear;
  %local i member;
  %do i=1 %to 3;
    %let member=%scan(_rbciu_colsupport _rbciu_cert _rbciu_certsupport,&i);
    %if %sysfunc(exist(work.&member,DATA)) %then %do;
      proc datasets library=work nolist; delete &member / memtype=data; quit;
    %end;
  %end;
%mend;
%macro rbc_cr2_structural_unavailable(model_lib=,job_id=,source_lib=,prefix=,outlib=,
    scope=,policy=,integration_reason=);
%local i j member members bad n expected_cohort runid fitid p k nperson nused nplanned q nu
       uindex nactive ndistinct nlevel nwithin nd ncert badsupport badowner ncertcat
       owns_scratch xvars hvars idchars field;
%global RBC_IU_OK RBC_IU_REASON RBC_ARCHIVE_REASON;
%let RBC_IU_OK=0; %let RBC_IU_REASON=NOT_COMPLETED; %let owns_scratch=0;
%if not %sysmacexist(rbc_archive_schema) or not %sysmacexist(rbc_fit_bind_outputs) %then %do;
  %rbc_iu_reject(reason=MODULE_REQUIRED); %return;
%end;
 
%if %superq(policy) ne SINGLE_PERSON_CATEGORY_CR2_UNAVAILABLE_V1 %then %do;
  %rbc_iu_reject(reason=STRUCTURAL_POLICY_INVALID); %return;
%end;
%if %superq(integration_reason) ne PLANNED_TARGET_NOT_LOO_ESTIMABLE %then %do;
  %rbc_iu_reject(reason=KERNEL_REASON_NOT_ELIGIBLE); %return;
%end;
%if %superq(scope) ne SYNTHETIC_DATA_ONLY and %superq(scope) ne LOCAL_SAMPLE_MODEL_INFERENCE and
    %superq(scope) ne FULL_COHORT_MODEL_INFERENCE %then %do;
  %rbc_iu_reject(reason=SCOPE_INVALID); %return;
%end;
%if %length(%superq(prefix))<1 or %length(%superq(prefix))>9 or %length(%superq(job_id))<1 or
    %length(%superq(job_id))>12 or %length(%superq(model_lib))<1 or %length(%superq(model_lib))>8 or
    %length(%superq(source_lib))<1 or %length(%superq(source_lib))>8 or
    %length(%superq(outlib))<1 or %length(%superq(outlib))>8 %then %do;
  %rbc_iu_reject(reason=INVALID_NAMES); %return;
%end;
%if not %sysfunc(nvalid(%superq(prefix),V7)) or not %sysfunc(nvalid(%superq(job_id),V7)) or
    not %sysfunc(nvalid(%superq(model_lib),V7)) or not %sysfunc(nvalid(%superq(source_lib),V7)) or
    not %sysfunc(nvalid(%superq(outlib),V7)) %then %do;
  %rbc_iu_reject(reason=INVALID_NAMES); %return;
%end;
%if %sysfunc(libref(&model_lib)) ne 0 or %sysfunc(libref(&source_lib)) ne 0 or
    %sysfunc(libref(&outlib)) ne 0 %then %do;
  %rbc_iu_reject(reason=UNASSIGNED_LIBRARY); %return;
%end;
%if &syscc>4 %then %do; %rbc_iu_reject(reason=PRIOR_SAS_FAILURE); %return; %end;
 
proc sql noprint;
  select count(*) into :n trimmed from dictionary.tables
  where libname=upcase("&outlib") and index(memname,"%upcase(&prefix._IU_)")=1;
quit;
%if &n ne 0 %then %do; %rbc_iu_reject(reason=TARGET_EXISTS); %return; %end;
%do i=1 %to 3;
  %let member=%scan(_rbciu_colsupport _rbciu_cert _rbciu_certsupport,&i);
  %if %sysfunc(exist(work.&member,DATA)) or %sysfunc(exist(work.&member,VIEW)) %then %do;
    %rbc_iu_reject(reason=SCRATCH_TARGET_EXISTS); %return;
  %end;
%end;
%let members=identity job_status fitmetadata cat_availability contrast_plan family_plan categories;
%do i=1 %to %sysfunc(countw(&members));
  %let member=%scan(&members,&i);
  %if not %sysfunc(exist(&model_lib..&job_id._&member,DATA)) or
      %sysfunc(exist(&model_lib..&job_id._&member,VIEW)) %then %do;
    %rbc_iu_reject(reason=WORKING_MEMBER_MISSING); %return;
  %end;
%end;
%let members=identity status si_status cs_support cs_context cs_status target_design target_keys;
%do i=1 %to %sysfunc(countw(&members));
  %let member=%scan(&members,&i);
  %if not %sysfunc(exist(&source_lib..&prefix._&member,DATA)) or
      %sysfunc(exist(&source_lib..&prefix._&member,VIEW)) %then %do;
    %rbc_iu_reject(reason=SOURCE_MEMBER_MISSING); %return;
  %end;
%end;

%let members=si_inference si_covariance si_basis si_bread si_moment si_spanbasis si_spanrobust
  si_solution si_context si_root_summary si_moment_error si_scalar_weights si_scalar_certificate
  all_targets levels changes within pairwise joint joint_weights joint_certificate
  certificate_context lc_points scalar_unavailable;
%do i=1 %to %sysfunc(countw(&members));
  %let member=%scan(&members,&i);
  %if %sysfunc(exist(&source_lib..&prefix._&member,DATA)) or
      %sysfunc(exist(&source_lib..&prefix._&member,VIEW)) %then %do;
    %rbc_iu_reject(reason=STATISTICS_PRESENT); %return;
  %end;
%end;
%let idchars=RunId AnalysisSpecId CohortMode PopulationId FitId InputSnapshotId CodeHash ConfigHash
  DesignId ProfileId JobID SubjectKeySource SubjectAlias DesignIdentityKind ProfileIdentityKind;
%let RBC_ARCHIVE_REASON=;
%rbc_iu_schema(data=&model_lib..&job_id._identity,chars=&idchars DFMethod InferenceStatus,nums=BindingVersion);
%rbc_iu_schema(data=&model_lib..&job_id._job_status,chars=JobStatus ReasonCode,nums=FitAttempted);
%rbc_iu_schema(data=&model_lib..&job_id._fitmetadata,chars=FitStatus,
  nums=N_DesignColumns N_Categories N_Patients N_Used EngineRunChecksPassed);
%rbc_iu_schema(data=&model_lib..&job_id._cat_availability,chars=AvailabilityReason,
  nums=CategoryCode CategoryIndex N_Observations N_Patients Available);
%rbc_iu_schema(data=&model_lib..&job_id._family_plan,
  chars=FamilyID FamilyRole FactorName Model VitalCode PAdjustment CIAdjustment FreezeStage,
  nums=PlannedCategories AvailableCategories PlannedPairs ActivePairs PlanVersion);
%rbc_iu_schema(data=&model_lib..&job_id._contrast_plan,chars=ContrastID ContrastType ExclusionReason FamilyID,
  nums=CategoryCodeA CategoryCodeB CategoryIndexA CategoryIndexB Planned Active BeforeMinute AfterMinute);
%rbc_iu_schema(data=&source_lib..&prefix._identity,chars=&idchars Scope InferenceStatus CR2ArchiveID,nums=);
%rbc_iu_schema(data=&source_lib..&prefix._status,chars=IntegrationStatus ReasonCode,nums=);
%rbc_iu_schema(data=&source_lib..&prefix._si_status,chars=RunId FitId Scope cr2rc,nums=);
%rbc_iu_schema(data=&source_lib..&prefix._cs_status,chars=RunId FitId Scope qrstatus,nums=);
%rbc_iu_schema(data=&source_lib..&prefix._cs_context,chars=RunId FitId Scope StatisticKind,
  nums=ParameterCount ClusterCount ObservationCount);
%rbc_iu_schema(data=&source_lib..&prefix._target_keys,chars=,nums=TargetIndex TargetKind CategoryIndexA);
%if %length(&RBC_ARCHIVE_REASON)>0 %then %do; %rbc_iu_reject(reason=INPUT_SCHEMA_INVALID); %return; %end;
%let expected_cohort=synthetic;
%if %superq(scope)=LOCAL_SAMPLE_MODEL_INFERENCE %then %let expected_cohort=development_sample;
%else %if %superq(scope)=FULL_COHORT_MODEL_INFERENCE %then %let expected_cohort=full_cohort;
 
%let n=0; %let bad=1; %let runid=; %let fitid=;
proc sql noprint;
  select count(*),coalesce(sum(CohortMode ne "&expected_cohort" or upcase(JobID) ne upcase("&job_id")
      or BindingVersion ne 1 or InferenceStatus ne 'MODEL_BASED_CANDIDATE' or DFMethod ne 'RESIDUAL'
      or not prxmatch('/^[0-9a-fA-F]{32}$/',strip(RunId)) or missing(FitId)),1)
    into :n trimmed,:bad trimmed from &model_lib..&job_id._identity;
  select RunId,FitId into :runid trimmed,:fitid trimmed from &model_lib..&job_id._identity;
quit;
%if &syscc>4 or &n ne 1 or &bad ne 0 %then %do; %rbc_iu_reject(reason=WORKING_IDENTITY_INVALID); %return; %end;
%let n=0; %let bad=1;
proc sql noprint;
  select count(*),coalesce(sum(JobStatus ne 'FIT_CHECKS_PASSED' or ReasonCode ne 'NONE' or FitAttempted ne 1),1)
    into :n trimmed,:bad trimmed from &model_lib..&job_id._job_status;
quit;
%if &syscc>4 or &n ne 1 or &bad ne 0 %then %do; %rbc_iu_reject(reason=WORKING_FIT_NOT_COMPLETE); %return; %end;
%let n=0; %let bad=1; %let p=0; %let k=0; %let nperson=0; %let nused=0;
proc sql noprint;
  select count(*),coalesce(sum(FitStatus ne 'FIT_CHECKS_PASSED' or EngineRunChecksPassed ne 1
      or nmiss(N_DesignColumns,N_Categories,N_Patients,N_Used)>0
      or N_DesignColumns<1 or N_DesignColumns>200 or N_DesignColumns ne int(N_DesignColumns)
      or N_Categories<2 or N_Categories>7 or N_Categories ne int(N_Categories)
      or N_Patients<2 or N_Patients ne int(N_Patients) or N_Used<N_Patients or N_Used ne int(N_Used)),1)
    into :n trimmed,:bad trimmed from &model_lib..&job_id._fitmetadata;
  select N_DesignColumns format=32.,N_Categories format=32.,N_Patients format=32.,N_Used format=32.
    into :p trimmed,:k trimmed,:nperson trimmed,:nused trimmed from &model_lib..&job_id._fitmetadata;
quit;
%if &syscc>4 or &n ne 1 or &bad ne 0 %then %do; %rbc_iu_reject(reason=WORKING_FIT_NOT_COMPLETE); %return; %end;
%let n=0; %let bad=1; %let nplanned=0;
proc sql noprint;
  select count(*),coalesce(sum(PlanVersion ne 1 or FreezeStage ne 'PRE_FIT' or AvailableCategories ne &k
      or PlannedCategories<&k or PlannedCategories>7 or PlannedCategories ne int(PlannedCategories)
      or ActivePairs ne &k*(&k-1)/2),1),max(PlannedCategories) format=32.
    into :n trimmed,:bad trimmed,:nplanned trimmed from &model_lib..&job_id._family_plan;
quit;
%if &syscc>4 or &n ne 1 or &bad ne 0 %then %do; %rbc_iu_reject(reason=FROZEN_FAMILY_INVALID); %return; %end;
 
%let n=0; %let bad=1;
proc sql noprint;
  select count(*),coalesce(sum(IntegrationStatus ne 'REJECTED' or ReasonCode ne 'PLANNED_TARGET_NOT_LOO_ESTIMABLE'),1)
    into :n trimmed,:bad trimmed from &source_lib..&prefix._status;
quit;
%if &syscc>4 or &n ne 1 or &bad ne 0 %then %do; %rbc_iu_reject(reason=INTEGRATION_STATUS_MISMATCH); %return; %end;
%let n=0; %let bad=1;
proc sql noprint;
  select count(*),coalesce(sum(cr2rc ne 'PLANNED_TARGET_NOT_LOO_ESTIMABLE' or RunId ne "&runid"
      or FitId ne "&fitid" or Scope ne "&scope"),1)
    into :n trimmed,:bad trimmed from &source_lib..&prefix._si_status;
quit;
%if &syscc>4 or &n ne 1 or &bad ne 0 %then %do; %rbc_iu_reject(reason=KERNEL_STATUS_MISMATCH); %return; %end;
%let n=0; %let bad=1;
proc sql noprint;
  select count(*),coalesce(sum(RunId ne "&runid" or FitId ne "&fitid" or upcase(JobID) ne upcase("&job_id")
      or Scope ne "&scope" or InferenceStatus ne 'CR2_VALIDATION_PENDING' or CR2ArchiveID ne "&prefix"),1)
    into :n trimmed,:bad trimmed from &source_lib..&prefix._identity;
quit;
%if &syscc>4 or &n ne 1 or &bad ne 0 %then %do; %rbc_iu_reject(reason=FACADE_IDENTITY_MISMATCH); %return; %end;
 
%let bad=0;
data _null_;
  if _n_=1 then set &model_lib..&job_id._identity(keep=&idchars rename=(
    %do j=1 %to %sysfunc(countw(&idchars)); %let field=%scan(&idchars,&j); &field=_IUW_&field %end;
  ));
  set &source_lib..&prefix._identity(keep=&idchars);
  %do j=1 %to %sysfunc(countw(&idchars));
    %let field=%scan(&idchars,&j);
    if &field ne _IUW_&field then call symputx('bad',1,'L');
  %end;
run;
%if &syscc>4 or &bad ne 0 %then %do; %rbc_iu_reject(reason=FACADE_IDENTITY_MISMATCH); %return; %end;
%let n=0; %let bad=1;
proc sql noprint;
  select count(*),coalesce(sum(qrstatus ne 'PASS' or RunId ne "&runid" or FitId ne "&fitid" or Scope ne "&scope"),1)
    into :n trimmed,:bad trimmed from &source_lib..&prefix._cs_status;
quit;
%if &syscc>4 or &n ne 1 or &bad ne 0 %then %do; %rbc_iu_reject(reason=SUPPORT_CONTEXT_MISMATCH); %return; %end;
%let n=0; %let bad=1;
proc sql noprint;
  select count(*),coalesce(sum(RunId ne "&runid" or FitId ne "&fitid" or Scope ne "&scope"
      or StatisticKind ne 'AUGMENTED_QR' or ParameterCount ne &p or ClusterCount ne &nperson
      or ObservationCount ne &nused),1)
    into :n trimmed,:bad trimmed from &source_lib..&prefix._cs_context;
quit;
%if &syscc>4 or &n ne 1 or &bad ne 0 %then %do; %rbc_iu_reject(reason=SUPPORT_CONTEXT_MISMATCH); %return; %end;
%let xvars=; %let hvars=;
%do i=1 %to &p; %let xvars=&xvars RBCX&i; %let hvars=&hvars HasX&i; %end;
%let RBC_ARCHIVE_REASON=;
%rbc_iu_schema(data=&source_lib..&prefix._cs_support,chars=RunId FitId Scope,nums=Cluster &hvars);
%rbc_iu_schema(data=&source_lib..&prefix._target_design,chars=,nums=TargetIndex &xvars);
%if %length(&RBC_ARCHIVE_REASON)>0 %then %do; %rbc_iu_reject(reason=INPUT_SCHEMA_INVALID); %return; %end;
 
%let n=0; %let bad=1; %let nactive=0; %let nu=0; %let ndistinct=0;
proc sql noprint;
  select count(*),coalesce(sum(Available not in (0,1) or nmiss(N_Patients,N_Observations)>0
      or (Available=1 and (missing(CategoryIndex) or CategoryIndex<1 or CategoryIndex>&k
        or CategoryIndex ne int(CategoryIndex) or N_Patients<1 or N_Observations<N_Patients))
      or (Available=0 and (not missing(CategoryIndex) or N_Patients ne 0))),1),
    coalesce(sum(Available=1),0),coalesce(sum(Available=1 and N_Patients=1),0)
    into :n trimmed,:bad trimmed,:nactive trimmed,:nu trimmed from &model_lib..&job_id._cat_availability;
  select count(distinct CategoryIndex) into :ndistinct trimmed
    from &model_lib..&job_id._cat_availability where Available=1;
quit;
%if &syscc>4 or &n ne &nplanned or &bad ne 0 or &nactive ne &k or &ndistinct ne &k %then %do;
  %rbc_iu_reject(reason=FROZEN_PLAN_INVALID); %return;
%end;
%if &nu<1 %then %do; %rbc_iu_reject(reason=NO_SINGLE_PERSON_ACTIVE_CATEGORY); %return; %end;
%let uindex=;
proc sql noprint;
  select CategoryIndex format=32. into :uindex separated by ' '
    from &model_lib..&job_id._cat_availability where Available=1 and N_Patients=1 order by CategoryIndex;
quit;
%if &syscc>4 or %length(&uindex)=0 %then %do; %rbc_iu_reject(reason=FROZEN_PLAN_INVALID); %return; %end;
%if %sysfunc(countw(&uindex,%str( ))) ne &nu %then %do; %rbc_iu_reject(reason=FROZEN_PLAN_INVALID); %return; %end;
%let q=%eval(2*1441*&k+&k+&k*(&k-1)/2);
%let n=0; %let nlevel=0; %let nwithin=0; %let nd=0;
proc sql noprint;
  select count(*),coalesce(sum(TargetKind=1),0),coalesce(sum(TargetKind=3),0)
    into :n trimmed,:nlevel trimmed,:nwithin trimmed from &source_lib..&prefix._target_keys;
  select count(*) into :nd trimmed from &source_lib..&prefix._target_design;
quit;
%if &syscc>4 or &n ne &q or &nd ne &q or &nlevel ne %eval(1441*&k) or &nwithin ne &k %then %do;
  %rbc_iu_reject(reason=TARGET_FAMILY_CARDINALITY); %return;
%end;
 
%let owns_scratch=1;
 
%let bad=1;
data work._rbciu_colsupport(keep=ColumnIndex SupportPersons OwnerCluster);
  set &source_lib..&prefix._cs_support(keep=Cluster &hvars RunId FitId Scope) end=_rbciu_last;
  array _rbciu_h{&p} &hvars;
  array _rbciu_s{&p} _temporary_;
  array _rbciu_o{&p} _temporary_;
  retain _rbciu_bad 0;
  if _n_=1 then do _rbciu_j=1 to &p; _rbciu_s{_rbciu_j}=0; _rbciu_o{_rbciu_j}=.; end;
  if Cluster ne _n_ or RunId ne "&runid" or FitId ne "&fitid" or Scope ne "&scope" then _rbciu_bad=1;
  do _rbciu_j=1 to &p;
    if _rbciu_h{_rbciu_j} not in (0,1) then _rbciu_bad=1;
    else if _rbciu_h{_rbciu_j}=1 then do;
      _rbciu_s{_rbciu_j}=_rbciu_s{_rbciu_j}+1; _rbciu_o{_rbciu_j}=Cluster;
    end;
  end;
  if _rbciu_last then do;
    if _n_ ne &nperson then _rbciu_bad=1;
    do _rbciu_j=1 to &p;
      ColumnIndex=_rbciu_j; SupportPersons=_rbciu_s{_rbciu_j}; OwnerCluster=_rbciu_o{_rbciu_j}; output;
    end;
    call symputx('bad',_rbciu_bad,'L');
  end;
run;
%if &syscc>4 or &bad ne 0 %then %do; %rbc_iu_reject(reason=RAW_SUPPORT_INVALID); %goto finish; %end;

%let bad=1;
data work._rbciu_cert(keep=CategoryIndex ColumnIndex);
  set &source_lib..&prefix._target_keys(keep=TargetIndex TargetKind CategoryIndexA) end=_rbciu_last;
  set &source_lib..&prefix._target_design(keep=TargetIndex &xvars rename=(TargetIndex=_rbciu_ti));
  array _rbciu_x{&p} &xvars;
  array _rbciu_nz{&k,&p} _temporary_;
  array _rbciu_lev{&k} _temporary_;
  retain _rbciu_prev 0 _rbciu_bad 0;
  if _n_=1 then do _rbciu_c=1 to &k;
    _rbciu_lev{_rbciu_c}=0;
    do _rbciu_j=1 to &p; _rbciu_nz{_rbciu_c,_rbciu_j}=0; end;
  end;
  if TargetIndex ne _n_ or _rbciu_ti ne _n_ or missing(TargetKind) or TargetKind not in (1,2,3,4)
     or TargetKind<_rbciu_prev or nmiss(of _rbciu_x{*})>0 then _rbciu_bad=1;
  _rbciu_prev=TargetKind;
  if TargetKind in (1,3) and (missing(CategoryIndexA) or CategoryIndexA<1 or CategoryIndexA>&k
     or CategoryIndexA ne int(CategoryIndexA)) then _rbciu_bad=1;
  else if TargetKind=1 then do;
    _rbciu_lev{CategoryIndexA}=_rbciu_lev{CategoryIndexA}+1;
    do _rbciu_j=1 to &p;
      if _rbciu_x{_rbciu_j} ne 0 then _rbciu_nz{CategoryIndexA,_rbciu_j}=1;
    end;
  end;
  else if TargetKind=3 and CategoryIndexA in (&uindex) then do _rbciu_j=1 to &p;
    if _rbciu_x{_rbciu_j} ne 0 and _rbciu_nz{CategoryIndexA,_rbciu_j}=1 then do;
      _rbciu_other=0;
      do _rbciu_c=1 to &k;
        if _rbciu_c ne CategoryIndexA then _rbciu_other=_rbciu_other+_rbciu_nz{_rbciu_c,_rbciu_j};
      end;
      if _rbciu_other=0 then do; CategoryIndex=CategoryIndexA; ColumnIndex=_rbciu_j; output; end;
    end;
  end;
  if _rbciu_last then do;
    if _n_ ne &q then _rbciu_bad=1;
    do _rbciu_c=1 to &k; if _rbciu_lev{_rbciu_c} ne 1441 then _rbciu_bad=1; end;
    call symputx('bad',_rbciu_bad,'L');
  end;
run;
%if &syscc>4 or &bad ne 0 %then %do; %rbc_iu_reject(reason=TARGET_DESIGN_INVALID); %goto finish; %end;
%let ncert=0; %let badsupport=1; %let badowner=1; %let ncertcat=0;
proc sql noprint;
  create table work._rbciu_certsupport as
    select c.CategoryIndex,c.ColumnIndex,s.SupportPersons,s.OwnerCluster
    from work._rbciu_cert c left join work._rbciu_colsupport s on c.ColumnIndex=s.ColumnIndex
    order by c.CategoryIndex,c.ColumnIndex;
  select count(*),coalesce(sum(missing(SupportPersons) or SupportPersons ne 1 or missing(OwnerCluster)),0)
    into :ncert trimmed,:badsupport trimmed from work._rbciu_certsupport;
  select count(*) into :badowner trimmed from
    (select CategoryIndex from work._rbciu_certsupport group by CategoryIndex having count(distinct OwnerCluster) ne 1);
  select count(distinct CategoryIndex) into :ncertcat trimmed from work._rbciu_certsupport;
quit;
%if &syscc>4 %then %do; %rbc_iu_reject(reason=SUPPORT_CERTIFICATE_SAS_FAILURE); %goto finish; %end;
%if &ncert<1 or &ncertcat ne &nu %then %do;
  %rbc_iu_reject(reason=SUPPORT_CERTIFICATE_EMPTY); %goto finish;
%end;
%if &badsupport ne 0 or &badowner ne 0 %then %do;
  %rbc_iu_reject(reason=SUPPORT_CERTIFICATE_NOT_SUBSTANTIATED); %goto finish;
%end;
 
data &outlib..&prefix._iu_identity;
  length Scope $32 PlannedCovarianceMethod $40 InferenceStatus $32 InferencePolicy $48
    InferenceArchiveID $12 SupportCertificate $40;
  set &model_lib..&job_id._identity(keep=&idchars DFMethod InferenceStatus BindingVersion
    rename=(DFMethod=WorkingDFMethod InferenceStatus=WorkingInferenceStatus BindingVersion=WorkingBindingVersion));
  Scope="&scope"; PlannedCovarianceMethod='GLS_WHITENED_CR2'; InferenceStatus='CR2_INFERENCE_UNAVAILABLE';
  InferencePolicy="&policy"; InferenceArchiveID="&prefix"; SupportCertificate='EXCLUSIVE_CATEGORY_SUPPORT_V1';
  BindingVersion=1;
run;
data &outlib..&prefix._iu_status;
  length IntegrationStatus $32 ReasonCode $64 SupportReason $40 UnavailableScope $32 TargetClaim $48
    StatisticsPolicy $32;
  IntegrationStatus='EXPECTED_INFERENCE_UNAVAILABLE'; ReasonCode='PLANNED_TARGET_NOT_LOO_ESTIMABLE';
  SupportReason='ACTIVE_CATEGORY_SINGLE_PERSON'; UnavailableScope='WHOLE_PLANNED_CR2_FAMILY';
  TargetClaim='AT_LEAST_ONE_PLANNED_TARGET_NOT_LOO_ESTIMABLE'; StatisticsPolicy='NO_CR2_STATISTICS_EXPORTED';
  PlannedCategories=&nplanned; ActiveCategories=&k; PlannedScalarTargets=&q;
  PlannedJointTests=%eval(2*(&k>1)); SinglePersonCategories=&nu; CertificateColumns=&ncert;
  ParameterCount=&p; ClusterCount=&nperson;
run;
data &outlib..&prefix._iu_cat_availability;
  set &model_lib..&job_id._cat_availability(keep=CategoryCode CategoryIndex Available AvailabilityReason);
run;
data &outlib..&prefix._iu_contrast_plan;
  set &model_lib..&job_id._contrast_plan(keep=ContrastID ContrastType CategoryCodeA CategoryCodeB
    CategoryIndexA CategoryIndexB Planned Active ExclusionReason FamilyID BeforeMinute AfterMinute);
run;
data &outlib..&prefix._iu_family_plan;
  set &model_lib..&job_id._family_plan(keep=FamilyID FamilyRole FactorName Model VitalCode PlannedCategories
    AvailableCategories PlannedPairs ActivePairs PAdjustment CIAdjustment FreezeStage PlanVersion);
run;
proc sql;
  create table &outlib..&prefix._iu_support_certificate as
    select 'WITHIN_TARGET_EXCLUSIVE_COLUMN' as CertificateKind length=32,a.CategoryCode,
      c.CategoryIndex,c.ColumnIndex,1 as WithinCoefficientNonzero,1 as CategorySpecificInScoring,
      min(c.SupportPersons,2) as SupportPersonsCappedAt2
    from work._rbciu_certsupport c inner join &model_lib..&job_id._cat_availability a
      on a.Available=1 and a.CategoryIndex=c.CategoryIndex
    order by a.CategoryCode,c.ColumnIndex;
quit;
%if &syscc>4 or &syserr>4 %then %do; %rbc_iu_reject(reason=OUTPUT_CONSTRUCTION_FAILED); %goto finish; %end;
%let n=0;
proc sql noprint;
  select count(*) into :n trimmed from &outlib..&prefix._iu_support_certificate;
quit;
%if &n ne &ncert %then %do; %rbc_iu_reject(reason=OUTPUT_CONSTRUCTION_FAILED); %goto finish; %end;
 
%rbc_fit_bind_outputs(outlib=&outlib,job_id=&prefix._iu,
  roles=status cat_availability contrast_plan family_plan support_certificate);
%if &syscc>4 or &syserr>4 %then %do; %rbc_iu_reject(reason=OUTPUT_BINDING_FAILED); %goto finish; %end;
%let RBC_IU_OK=1; %let RBC_IU_REASON=EXPECTED_INFERENCE_UNAVAILABLE;
%finish:
%if &owns_scratch=1 %then %rbc_iu_scratch_clear;
%if &RBC_IU_OK=1 and (&syscc>4 or %sysfunc(exist(work._rbciu_cert,DATA))) %then
  %rbc_iu_reject(reason=SCRATCH_CLEANUP_FAILED);
%mend;

%macro rbc_iu_role_fields(role=);
  %let chars=; %let nums=; %let expected=-1;
  %if &role=identity %then %let expected=1;
  %else %if &role=status %then %do;
    %let chars=IntegrationStatus ReasonCode SupportReason UnavailableScope TargetClaim StatisticsPolicy;
    %let nums=PlannedCategories ActiveCategories PlannedScalarTargets PlannedJointTests SinglePersonCategories CertificateColumns ParameterCount ClusterCount;
    %let expected=1;
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
  %else %if &role=support_certificate %then %do;
    %let chars=CertificateKind;
    %let nums=CategoryCode CategoryIndex ColumnIndex WithinCoefficientNonzero CategorySpecificInScoring SupportPersonsCappedAt2;
    %let expected=&ncert;
  %end;
%mend;
%macro rbc_export_cr2_iu(outlib=,prefix=,exportlib=);
%local context_chars context_nums context roles nroles i j role chars nums expected n bad field
       path prior_decimal k planned ncert dsid rc row1 row2 row3 row4 row5 row6
       col1 col2 col3 col4 col5 col6;
%global RBC_IU_EXPORT_OK RBC_IU_EXPORT_REASON RBC_ARCHIVE_REASON;
%let RBC_IU_EXPORT_OK=0; %let RBC_IU_EXPORT_REASON=NOT_COMPLETED;
%if not %sysmacexist(rbc_archive_schema) or not %sysmacexist(rbc_export_exact_csv) %then %do;
  %rbc_iu_export_reject(reason=EXPORT_MODULE_REQUIRED); %return;
%end;
%if %length(%superq(prefix))<1 or %length(%superq(prefix))>9 or
    %length(%superq(outlib))<1 or %length(%superq(outlib))>8 or
    %length(%superq(exportlib))<1 or %length(%superq(exportlib))>8 %then %do;
  %rbc_iu_export_reject(reason=INVALID_NAMES); %return;
%end;
%if not %sysfunc(nvalid(%superq(prefix),V7)) or not %sysfunc(nvalid(%superq(outlib),V7)) or
    not %sysfunc(nvalid(%superq(exportlib),V7)) or %sysfunc(libref(&outlib)) ne 0 or
    %sysfunc(libref(&exportlib)) ne 0 %then %do;
  %rbc_iu_export_reject(reason=INVALID_LIBRARIES); %return;
%end;
%if %sysfunc(fileref(_rbciux))<=0 or %sysfunc(exist(work._rbciu_stage,DATA)) or
    %sysfunc(exist(work._rbciu_stage,VIEW)) or %sysfunc(exist(work._rbciu_manifest,DATA)) or
    %sysfunc(exist(work._rbciu_manifest,VIEW)) %then %do;
  %rbc_iu_export_reject(reason=EXPORT_SCRATCH_COLLISION); %return;
%end;
%if &syscc>4 %then %do; %rbc_iu_export_reject(reason=PRIOR_SAS_FAILURE); %return; %end;
%let context_chars=RunId AnalysisSpecId CohortMode PopulationId FitId InputSnapshotId CodeHash ConfigHash DesignId ProfileId JobID SubjectKeySource SubjectAlias DesignIdentityKind ProfileIdentityKind WorkingDFMethod WorkingInferenceStatus Scope PlannedCovarianceMethod InferenceStatus InferencePolicy InferenceArchiveID SupportCertificate;
%let context_nums=BindingVersion WorkingBindingVersion;
%let context=&context_chars &context_nums;
%let roles=identity status cat_availability contrast_plan family_plan support_certificate;
%let nroles=%sysfunc(countw(&roles));
%do i=1 %to &nroles;
  %let role=%scan(&roles,&i);
  %if not %sysfunc(exist(&outlib..&prefix._iu_&role,DATA)) or
      %sysfunc(exist(&outlib..&prefix._iu_&role,VIEW)) %then %do;
    %rbc_iu_export_reject(reason=SOURCE_DATA_MEMBER_REQUIRED); %return;
  %end;
%end;
%let RBC_ARCHIVE_REASON=;
%rbc_iu_schema(data=&outlib..&prefix._iu_identity,chars=&context_chars,nums=&context_nums);
%rbc_iu_schema(data=&outlib..&prefix._iu_status,
  chars=&context_chars IntegrationStatus ReasonCode SupportReason UnavailableScope TargetClaim StatisticsPolicy,
  nums=&context_nums PlannedCategories ActiveCategories PlannedScalarTargets PlannedJointTests SinglePersonCategories CertificateColumns ParameterCount ClusterCount);
%if %length(&RBC_ARCHIVE_REASON)>0 %then %do; %rbc_iu_export_reject(reason=INPUT_SCHEMA_INVALID); %return; %end;
%let bad=0; %let n=0;
data _null_;
  set &outlib..&prefix._iu_identity end=last;
  if _n_ ne 1 or cmiss(of &context_chars)>0 or BindingVersion ne 1 or WorkingBindingVersion ne 1
     or WorkingDFMethod ne 'RESIDUAL' or WorkingInferenceStatus ne 'MODEL_BASED_CANDIDATE'
     or PlannedCovarianceMethod ne 'GLS_WHITENED_CR2' or InferenceStatus ne 'CR2_INFERENCE_UNAVAILABLE'
     or InferencePolicy ne 'SINGLE_PERSON_CATEGORY_CR2_UNAVAILABLE_V1' or InferenceArchiveID ne "&prefix"
     or SupportCertificate ne 'EXCLUSIVE_CATEGORY_SUPPORT_V1'
     or not ((Scope='SYNTHETIC_DATA_ONLY' and CohortMode='synthetic') or
        (Scope='LOCAL_SAMPLE_MODEL_INFERENCE' and CohortMode='development_sample') or
        (Scope='FULL_COHORT_MODEL_INFERENCE' and CohortMode='full_cohort'))
     or not prxmatch('/^[0-9a-fA-F]{32}$/',strip(RunId))
     or not prxmatch('/^[0-9a-fA-F]{64}$/',strip(CodeHash))
     or not prxmatch('/^[0-9a-fA-F]{64}$/',strip(ConfigHash)) then call symputx('bad',1,'L');
  if last then call symputx('n',_n_,'L');
run;
%if &bad ne 0 or &n ne 1 or &syscc>4 %then %do; %rbc_iu_export_reject(reason=IDENTITY_INVALID); %return; %end;
%let n=0; %let k=0; %let planned=0; %let ncert=0;
data _null_;
  set &outlib..&prefix._iu_status end=last;
  if _n_ ne 1 or IntegrationStatus ne 'EXPECTED_INFERENCE_UNAVAILABLE'
     or ReasonCode ne 'PLANNED_TARGET_NOT_LOO_ESTIMABLE' or SupportReason ne 'ACTIVE_CATEGORY_SINGLE_PERSON'
     or UnavailableScope ne 'WHOLE_PLANNED_CR2_FAMILY'
     or TargetClaim ne 'AT_LEAST_ONE_PLANNED_TARGET_NOT_LOO_ESTIMABLE'
     or StatisticsPolicy ne 'NO_CR2_STATISTICS_EXPORTED'
     or nmiss(PlannedCategories,ActiveCategories,PlannedScalarTargets,PlannedJointTests,
        SinglePersonCategories,CertificateColumns,ParameterCount,ClusterCount)>0
     or ActiveCategories<2 or ActiveCategories ne int(ActiveCategories)
     or PlannedCategories<ActiveCategories or PlannedCategories>7 or PlannedCategories ne int(PlannedCategories)
     or PlannedScalarTargets ne 2*1441*ActiveCategories+ActiveCategories+ActiveCategories*(ActiveCategories-1)/2
     or PlannedJointTests ne 2 or SinglePersonCategories<1 or SinglePersonCategories>ActiveCategories
     or CertificateColumns<SinglePersonCategories or CertificateColumns>ParameterCount*SinglePersonCategories
     or ParameterCount<1 or ParameterCount>200 or ClusterCount<2 then call symputx('bad',1,'L');
  call symputx('k',ActiveCategories,'L'); call symputx('planned',PlannedCategories,'L');
  call symputx('ncert',CertificateColumns,'L');
  if last then call symputx('n',_n_,'L');
run;
%if &bad ne 0 or &n ne 1 or &syscc>4 %then %do; %rbc_iu_export_reject(reason=STATUS_INVALID); %return; %end;
%do i=1 %to &nroles;
  %let role=%scan(&roles,&i); %rbc_iu_role_fields(role=&role);
  %let RBC_ARCHIVE_REASON=;
  %rbc_iu_schema(data=&outlib..&prefix._iu_&role,chars=&context_chars &chars,nums=&context_nums &nums);
  %if %length(&RBC_ARCHIVE_REASON)>0 %then %do; %rbc_iu_export_reject(reason=INPUT_SCHEMA_INVALID); %return; %end;
  %let dsid=%sysfunc(open(&outlib..&prefix._iu_&role,i));
  %if &dsid=0 %then %do; %rbc_iu_export_reject(reason=SOURCE_DATA_MEMBER_REQUIRED); %return; %end;
  %let n=%sysfunc(attrn(&dsid,nlobs)); %let rc=%sysfunc(close(&dsid));
  %if &n ne &expected %then %do; %rbc_iu_export_reject(reason=ROW_CARDINALITY_INVALID); %return; %end;
  %let row&i=&n; %let col&i=%sysfunc(countw(&context &chars &nums));
  data _null_;
    if _n_=1 then set &outlib..&prefix._iu_identity(keep=&context rename=(
      %do j=1 %to %sysfunc(countw(&context)); %let field=%scan(&context,&j); &field=_IUC_&field %end;
    ));
    set &outlib..&prefix._iu_&role(keep=&context);
    %do j=1 %to %sysfunc(countw(&context)); %let field=%scan(&context,&j);
      if &field ne _IUC_&field then call symputx('bad',1,'L');
    %end;
  run;
  %if &bad ne 0 or &syscc>4 %then %do; %rbc_iu_export_reject(reason=CONTEXT_MISMATCH); %return; %end;
%end;
%let path=%qsysfunc(pathname(&exportlib));
data _null_;
  %do i=1 %to %eval(&nroles+1);
    %let role=archive_manifest; %if &i<=&nroles %then %let role=%scan(&roles,&i);
    rc=filename('_rbciux',cats(pathname("&exportlib"),'/',"&prefix._iu_&role..csv"));
    if rc ne 0 or fexist('_rbciux') then call symputx('bad',1,'L'); rc=filename('_rbciux');
  %end;
run;
%if &bad ne 0 or &syscc>4 %then %do; %rbc_iu_export_reject(reason=EXPORT_TARGET_NOT_FRESH); %return; %end;
%let prior_decimal=%sysfunc(getoption(decimalconv,keyword));
options decimalconv=stdieee;
%do i=1 %to &nroles;
  %let role=%scan(&roles,&i); %rbc_iu_role_fields(role=&role);
  data work._rbciu_stage;
    retain &context &chars &nums;
    set &outlib..&prefix._iu_&role(keep=&context &chars &nums);
    format _numeric_ e32.; format _character_;
  run;
  data _null_;
    rc=filename('_rbciux',cats(pathname("&exportlib"),'/',"&prefix._iu_&role..csv"));
    if rc ne 0 or fexist('_rbciux') then call symputx('bad',1,'L'); rc=filename('_rbciux');
  run;
  %if &bad ne 0 or &syscc>4 %then %goto export_failed;
  filename _rbciux "%superq(path)/&prefix._iu_&role..csv" encoding='utf-8' lrecl=1048576;
  %rbc_export_exact_csv(data=work._rbciu_stage,fileref=_rbciux);
  %if &RBC_EXACT_CSV_OK ne 1 %then %goto export_failed;
  filename _rbciux clear;
  %if &syscc>4 %then %goto export_failed;
%end;
 
data work._rbciu_manifest;
  retain &context;
  if _n_=1 then set &outlib..&prefix._iu_identity(keep=&context);
  length Protocol $48 Role $32 FileName $80 NumericFormat $16 TextEncoding $8 ExportStatus $24;
  Protocol='RBC_CR2_INFERENCE_UNAVAILABLE_ARCHIVE_V1'; NumericFormat='HEX16_IEEE754';
  TextEncoding='UTF-8'; ExportStatus='EXPORTED_LOCAL_ONLY';
  %do i=1 %to &nroles;
    %let role=%scan(&roles,&i); Role="&role"; FileName="&prefix._iu_&role..csv";
    RowCount=&&row&i; ColumnCount=&&col&i; output;
  %end;
  stop; format _numeric_ e32.;
run;
data _null_;
  rc=filename('_rbciux',cats(pathname("&exportlib"),'/',"&prefix._iu_archive_manifest.csv"));
  if rc ne 0 or fexist('_rbciux') then call symputx('bad',1,'L'); rc=filename('_rbciux');
run;
%if &bad ne 0 or &syscc>4 %then %goto export_failed;
filename _rbciux "%superq(path)/&prefix._iu_archive_manifest.csv" encoding='utf-8' lrecl=1048576;
%rbc_export_exact_csv(data=work._rbciu_manifest,fileref=_rbciux);
%if &RBC_EXACT_CSV_OK ne 1 %then %goto export_failed;
filename _rbciux clear;
%if &syscc>4 %then %goto export_failed;
options &prior_decimal;
proc datasets library=work nolist; delete _rbciu_stage _rbciu_manifest; quit;
%if &syscc>4 %then %do; %rbc_iu_export_reject(reason=EXPORT_CLEANUP_FAILED); %return; %end;
%let RBC_IU_EXPORT_OK=1; %let RBC_IU_EXPORT_REASON=EXPORTED_LOCAL_ONLY;
%return;
%export_failed:
  filename _rbciux clear;
  %if %sysfunc(exist(work._rbciu_stage,DATA)) %then %do;
    proc datasets library=work nolist; delete _rbciu_stage; quit;
  %end;
  %if %sysfunc(exist(work._rbciu_manifest,DATA)) %then %do;
    proc datasets library=work nolist; delete _rbciu_manifest; quit;
  %end;
  options &prior_decimal;
  %rbc_iu_export_reject(reason=EXPORT_WRITE_FAILED);
%mend;

%macro rbc_iu_guard_reject(reason=);
  %global RBC_IU_GUARD_OK RBC_IU_GUARD_REASON;
  %let RBC_IU_GUARD_OK=0; %let RBC_IU_GUARD_REASON=&reason;
  %put NOTE: RBC_CR2_SPCU_PASS_GUARD &reason;
%mend;
%macro rbc_cr2_spcu_pass_guard(model_lib=,job_id=,source_lib=,prefix=,scope=,policy=);
%local i member n bad runid fitid k nperson nplanned nactive nu ndistinct ncodes expected_cohort
       RBC_ARCHIVE_REASON;
%global RBC_IU_GUARD_OK RBC_IU_GUARD_REASON;
%let RBC_IU_GUARD_OK=0; %let RBC_IU_GUARD_REASON=NOT_COMPLETED;
 
%if %superq(policy) ne SINGLE_PERSON_CATEGORY_CR2_UNAVAILABLE_V1 %then %do;
  %rbc_iu_guard_reject(reason=STRUCTURAL_POLICY_INVALID); %return;
%end;
%if %superq(scope) ne SYNTHETIC_DATA_ONLY and %superq(scope) ne LOCAL_SAMPLE_MODEL_INFERENCE and
    %superq(scope) ne FULL_COHORT_MODEL_INFERENCE %then %do;
  %rbc_iu_guard_reject(reason=SCOPE_INVALID); %return;
%end;
%if %length(%superq(prefix))<1 or %length(%superq(prefix))>9 or %length(%superq(job_id))<1 or
    %length(%superq(job_id))>12 or %length(%superq(model_lib))<1 or %length(%superq(model_lib))>8 or
    %length(%superq(source_lib))<1 or %length(%superq(source_lib))>8 %then %do;
  %rbc_iu_guard_reject(reason=INVALID_NAMES); %return;
%end;
%if not %sysfunc(nvalid(%superq(prefix),V7)) or not %sysfunc(nvalid(%superq(job_id),V7)) or
    not %sysfunc(nvalid(%superq(model_lib),V7)) or not %sysfunc(nvalid(%superq(source_lib),V7)) %then %do;
  %rbc_iu_guard_reject(reason=INVALID_NAMES); %return;
%end;
%if %sysfunc(libref(&model_lib)) ne 0 or %sysfunc(libref(&source_lib)) ne 0 %then %do;
  %rbc_iu_guard_reject(reason=UNASSIGNED_LIBRARY); %return;
%end;
%if &syscc>4 %then %do; %rbc_iu_guard_reject(reason=PRIOR_SAS_FAILURE); %return; %end;
 
%if not %symexist(RBC_CR2_INTEGRATION_OK) %then %do;
  %rbc_iu_guard_reject(reason=GUARD_NOT_AFTER_CR2_SUCCESS); %return;
%end;
%if %superq(RBC_CR2_INTEGRATION_OK) ne 1 %then %do;
  %rbc_iu_guard_reject(reason=GUARD_NOT_AFTER_CR2_SUCCESS); %return;
%end;
%do i=1 %to 4;
  %let member=%scan(identity fitmetadata cat_availability family_plan,&i);
  %if not %sysfunc(exist(&model_lib..&job_id._&member,DATA)) or
      %sysfunc(exist(&model_lib..&job_id._&member,VIEW)) %then %do;
    %rbc_iu_guard_reject(reason=GUARD_INPUT_MISSING); %return;
  %end;
%end;
%do i=1 %to 2;
  %let member=%scan(identity status,&i);
  %if not %sysfunc(exist(&source_lib..&prefix._&member,DATA)) or
      %sysfunc(exist(&source_lib..&prefix._&member,VIEW)) %then %do;
    %rbc_iu_guard_reject(reason=GUARD_INPUT_MISSING); %return;
  %end;
%end;
 
%let RBC_ARCHIVE_REASON=;
%rbc_iu_schema(data=&model_lib..&job_id._identity,chars=RunId FitId JobID CohortMode,nums=);
%rbc_iu_schema(data=&model_lib..&job_id._fitmetadata,chars=FitStatus,nums=N_Categories N_Patients EngineRunChecksPassed);
%rbc_iu_schema(data=&model_lib..&job_id._cat_availability,chars=AvailabilityReason,
  nums=CategoryCode CategoryIndex N_Observations N_Patients Available);
%rbc_iu_schema(data=&model_lib..&job_id._family_plan,chars=FreezeStage,nums=PlannedCategories AvailableCategories PlanVersion);
%rbc_iu_schema(data=&source_lib..&prefix._identity,chars=RunId FitId JobID Scope InferenceStatus CR2ArchiveID,nums=);
%rbc_iu_schema(data=&source_lib..&prefix._status,
  chars=IntegrationStatus ReasonCode RunId FitId JobID Scope InferenceStatus CR2ArchiveID,nums=);
%if %length(%superq(RBC_ARCHIVE_REASON))>0 or &syscc>4 %then %do;
  %rbc_iu_guard_reject(reason=GUARD_SCHEMA_INVALID); %return;
%end;
%let expected_cohort=synthetic;
%if %superq(scope)=LOCAL_SAMPLE_MODEL_INFERENCE %then %let expected_cohort=development_sample;
%else %if %superq(scope)=FULL_COHORT_MODEL_INFERENCE %then %let expected_cohort=full_cohort;
 
%let n=0; %let bad=1; %let runid=; %let fitid=;
proc sql noprint;
  select count(*),coalesce(sum(CohortMode ne "&expected_cohort" or upcase(JobID) ne upcase("&job_id")
      or not prxmatch('/^[0-9a-fA-F]{32}$/',strip(RunId)) or missing(FitId)),1)
    into :n trimmed,:bad trimmed from &model_lib..&job_id._identity;
  select RunId,FitId into :runid trimmed,:fitid trimmed from &model_lib..&job_id._identity;
quit;
%if &syscc>4 or &n ne 1 or &bad ne 0 %then %do;
  %rbc_iu_guard_reject(reason=GUARD_WORKING_IDENTITY_INVALID); %return;
%end;
 
%let n=0; %let bad=1;
proc sql noprint;
  select count(*),coalesce(sum(RunId ne "&runid" or FitId ne "&fitid" or upcase(JobID) ne upcase("&job_id")
      or Scope ne "&scope" or InferenceStatus ne 'CR2_CHECKS_PASSED' or CR2ArchiveID ne "&prefix"),1)
    into :n trimmed,:bad trimmed from &source_lib..&prefix._identity;
quit;
%if &syscc>4 or &n ne 1 or &bad ne 0 %then %do;
  %rbc_iu_guard_reject(reason=GUARD_CR2_IDENTITY_MISMATCH); %return;
%end;
 
%let n=0; %let bad=1;
proc sql noprint;
  select count(*),coalesce(sum(IntegrationStatus ne 'CR2_CHECKS_PASSED' or ReasonCode ne 'PASS'
      or RunId ne "&runid" or FitId ne "&fitid" or upcase(JobID) ne upcase("&job_id") or Scope ne "&scope"
      or InferenceStatus ne 'CR2_CHECKS_PASSED' or CR2ArchiveID ne "&prefix"),1)
    into :n trimmed,:bad trimmed from &source_lib..&prefix._status;
quit;
%if &syscc>4 or &n ne 1 or &bad ne 0 %then %do;
  %rbc_iu_guard_reject(reason=GUARD_STATUS_INVALID); %return;
%end;
 
%let n=0; %let bad=1; %let k=0; %let nperson=0;
proc sql noprint;
  select count(*),coalesce(sum(FitStatus ne 'FIT_CHECKS_PASSED' or EngineRunChecksPassed ne 1
      or nmiss(N_Categories,N_Patients)>0 or N_Categories<1 or N_Categories>7
      or N_Categories ne int(N_Categories) or N_Patients<2 or N_Patients ne int(N_Patients)),1),
    max(N_Categories) format=32.,max(N_Patients) format=32.
    into :n trimmed,:bad trimmed,:k trimmed,:nperson trimmed from &model_lib..&job_id._fitmetadata;
quit;
%if &syscc>4 or &n ne 1 or &bad ne 0 %then %do;
  %rbc_iu_guard_reject(reason=GUARD_WORKING_FIT_INVALID); %return;
%end;
%let n=0; %let bad=1; %let nplanned=0;
proc sql noprint;
  select count(*),coalesce(sum(nmiss(PlanVersion,AvailableCategories,PlannedCategories)>0 or PlanVersion ne 1
      or FreezeStage ne 'PRE_FIT' or AvailableCategories ne &k or PlannedCategories<&k or PlannedCategories>7
      or PlannedCategories ne int(PlannedCategories)),1),max(PlannedCategories) format=32.
    into :n trimmed,:bad trimmed,:nplanned trimmed from &model_lib..&job_id._family_plan;
quit;
%if &syscc>4 or &n ne 1 or &bad ne 0 %then %do;
  %rbc_iu_guard_reject(reason=GUARD_CATEGORY_METADATA_INVALID); %return;
%end;

%let n=0; %let bad=1; %let nactive=0; %let nu=-1; %let ndistinct=0; %let ncodes=0;
proc sql noprint;
  select count(*),coalesce(sum(nmiss(CategoryCode,Available,N_Patients,N_Observations)>0
      or Available not in (0,1) or CategoryCode ne int(CategoryCode) or N_Patients ne int(N_Patients)
      or N_Observations ne int(N_Observations)
      or (Available=1 and (missing(CategoryIndex) or CategoryIndex<1 or CategoryIndex>&k
        or CategoryIndex ne int(CategoryIndex) or N_Patients<1 or N_Patients>&nperson
        or N_Observations<N_Patients))
      or (Available=0 and (not missing(CategoryIndex) or N_Patients ne 0))),1),
    coalesce(sum(Available=1),0),coalesce(sum(Available=1 and N_Patients=1),-1),
    count(distinct CategoryCode)
    into :n trimmed,:bad trimmed,:nactive trimmed,:nu trimmed,:ncodes trimmed
    from &model_lib..&job_id._cat_availability;
  select count(distinct CategoryIndex) into :ndistinct trimmed
    from &model_lib..&job_id._cat_availability where Available=1;
quit;
%if &syscc>4 or &n<1 or &n ne &nplanned or &bad ne 0 or &nactive ne &k or &ndistinct ne &k
    or &ncodes ne &n or &nu<0 %then %do;
  %rbc_iu_guard_reject(reason=GUARD_CATEGORY_METADATA_INVALID); %return;
%end;
%if &nu ne 0 %then %do;
  %rbc_iu_guard_reject(reason=SINGLE_PERSON_CATEGORY_CR2_PASS_CONTRADICTION); %return;
%end;
%let RBC_IU_GUARD_OK=1; %let RBC_IU_GUARD_REASON=PASS_NO_ACTIVE_SINGLE_PERSON_CATEGORY;
%put NOTE: RBC_CR2_SPCU_PASS_GUARD PASS_NO_ACTIVE_SINGLE_PERSON_CATEGORY;
%mend;

%macro rbc_lcpu_certificate_check(targets=,certificate=);
  %global RBC_LCPU_STATUS RBC_LCPU_COUNT;
  %local n bad badc;
  %let RBC_LCPU_STATUS=NOT_COMPLETED; %let RBC_LCPU_COUNT=.;
  %let n=-1; %let bad=1; %let badc=1;
  proc sql noprint;
    select count(*),coalesce(sum(missing(c.TargetIndex) or t.TargetKind not in (1,2) or t.ContrastStatus ne 4 or
        nmiss(c.Denominator,c.AbsError,c.RelativeErrorUpper,c.IdealRelativeErrorUpper,c.Resolved)>0 or
        c.Resolved ne 0 or c.Denominator<=0 or c.AbsError<0 or c.RelativeErrorUpper<0 or
        c.RelativeErrorUpper>=.25 or c.IdealRelativeErrorUpper<=2e-8),0)
      into :n trimmed,:bad trimmed
      from &targets t left join &certificate c on t.TargetIndex=c.TargetIndex
      where t.NumericStatus='MOMENT_PRECISION_UNRESOLVED';
    select coalesce(sum(missing(c.TargetIndex) or c.Resolved ne 1 or t.ContrastStatus ne 0),0)
      into :badc trimmed
      from &targets t left join &certificate c on t.TargetIndex=c.TargetIndex
      where t.NumericStatus='COMPUTED';
  quit;
  %if &syscc>4 or &syserr>4 %then %let RBC_LCPU_STATUS=LCPU_CERTIFICATE_SAS_FAILURE;
  %else %if &n<0 or &bad ne 0 %then %let RBC_LCPU_STATUS=UNAVAILABLE_CERTIFICATE_INVALID;
  %else %if &badc ne 0 %then %let RBC_LCPU_STATUS=COMPUTED_CERTIFICATE_UNRESOLVED;
  %else %do; %let RBC_LCPU_STATUS=PASS; %let RBC_LCPU_COUNT=&n; %end;
%mend;

%macro rbc_lcpu_points(targets=,solution=,design=,weights=,spanrobust=,out=,p=,h=,q=);
  %global RBC_LCPU_STATUS;
  %local xv hv i status _lcpu_cpu;
  %let RBC_LCPU_STATUS=NOT_COMPLETED; %let status=NOT_COMPLETED;
  %let xv=; %do i=1 %to &p; %let xv=&xv RBCX&i; %end;
  %let hv=; %do i=1 %to &h; %let hv=&hv COL&i; %end;
  data &out._req;
    set &targets(keep=TargetIndex NumericStatus);
    if NumericStatus='MOMENT_PRECISION_UNRESOLVED';
    keep TargetIndex;
  run;
  %if &syscc>4 or &syserr>4 %then %do; %let RBC_LCPU_STATUS=LCPU_POINTS_SAS_FAILURE; %return; %end;

  %let _lcpu_cpu=%sysfunc(getoption(cpucount,keyword));
  options cpucount=1;
  proc iml;
    lcrc=repeat(' ',1,64); lcrc='NOT_COMPLETED';
    start lcpuPoints(dummy) global(lcrc);
      use &out._req; read all var {TargetIndex} into ids; close &out._req;
      use &solution; read all var {Parameter Estimate} into sol; close &solution;
      use &design; read all var {TargetIndex} into ti; read all var {&xv} into C; close &design;
       
      use &weights; read all var {TargetIndex} into wi; read all var {&hv} into WTS; close &weights;
      use &spanrobust; read all var {&hv} into VR; close &spanrobust;
      if nrow(ids)<1 then do; lcrc='NO_UNAVAILABLE_TARGETS'; return; end;
      if nrow(sol)^=&p | nrow(ti)^=&q | nrow(wi)^=&q | ncol(C)^=&p | ncol(WTS)^=&h |
         nrow(VR)^=&h | ncol(VR)^=&h | countmiss(sol)+countmiss(ti)+countmiss(wi)+
         countmiss(C)+countmiss(WTS)+countmiss(VR)+countmiss(ids)>0 then do;
        lcrc='UNAVAILABLE_INPUT_SCHEMA'; return;
      end;
      if any(ti^=(1:&q)`) | any(wi^=(1:&q)`) then do; lcrc='UNAVAILABLE_INPUT_SCHEMA'; return; end;
      beta=j(&p,1,.);
      do index=1 to nrow(sol);
        pp=sol[index,1];
        if pp<1 | pp>&p | pp^=round(pp) then do; lcrc='UNAVAILABLE_INPUT_SCHEMA'; return; end;
        if beta[pp]^=. then do; lcrc='UNAVAILABLE_INPUT_SCHEMA'; return; end;
        beta[pp]=sol[index,2];
      end;
      if countmiss(beta)>0 then do; lcrc='UNAVAILABLE_INPUT_SCHEMA'; return; end;
      result=j(nrow(ids),2,.);
      do r=1 to nrow(ids);
        ci=ids[r];
        if ci<1 | ci>&q | ci^=round(ci) then do; lcrc='UNAVAILABLE_INPUT_SCHEMA'; return; end;
        estimate=C[ci,]*beta;
        wrow=WTS[ci,]; variance=wrow*VR*wrow`; reference=wrow*wrow`;
        if estimate=. | variance=. | reference=. then do; lcrc='UNAVAILABLE_POINT_OR_GEOMETRY_INVALID'; return; end;
        if variance<=0 | reference<=0 then do; lcrc='UNAVAILABLE_POINT_OR_GEOMETRY_INVALID'; return; end;
        result[r,]=ci||estimate;
      end;
      create &out from result[colname={'TargetIndex' 'PointEstimate'}]; append from result; close &out;
      lcrc='PASS';
    finish;
    dummy=0; run lcpuPoints(dummy);
    call symputx('status',lcrc,'L');
  quit;
  options &_lcpu_cpu;
  proc sql; drop table &out._req; quit;
  %if &syscc>4 or &syserr>4 %then %let RBC_LCPU_STATUS=LCPU_POINTS_SAS_FAILURE;
  %else %let RBC_LCPU_STATUS=&status;
%mend;
%macro rbc_lcpu_merge_points(targets=,points=);
  %global RBC_LCPU_STATUS;
  %local bad;
  %let RBC_LCPU_STATUS=NOT_COMPLETED; %let bad=0;
  data &targets;
    merge &targets(in=_rbclt) &points(in=_rbclp);
    by TargetIndex;
    if not _rbclt then call symputx('bad',1,'L');
    if _rbclp then do;
      if NumericStatus ne 'MOMENT_PRECISION_UNRESOLVED' or not missing(Estimate) or missing(PointEstimate)
        then call symputx('bad',1,'L');
      Estimate=PointEstimate;
    end;
    else if NumericStatus='MOMENT_PRECISION_UNRESOLVED' then call symputx('bad',1,'L');
    drop PointEstimate;
  run;
  %if &syscc>4 or &syserr>4 or &bad ne 0 %then %let RBC_LCPU_STATUS=UNAVAILABLE_POINT_MERGE_FAILED;
  %else %let RBC_LCPU_STATUS=PASS;
%mend;

%macro rbc_lcpu_working_checks(targets=,trajectory=,k=);
  %global RBC_LCPU_STATUS;
  %local n bad;
  %let RBC_LCPU_STATUS=NOT_COMPLETED; %let n=-1; %let bad=1;
  proc sql noprint;
    select count(*),coalesce(sum(missing(w.GridID) or missing(b.GridID) or
        nmiss(c.Estimate,w.Delta,w.Predicted,b.Predicted)>0 or
        abs(c.Estimate-w.Delta)>1e-8*(max(1,abs(w.Predicted))+max(1,abs(b.Predicted)))),0)
      into :n trimmed,:bad trimmed
      from &targets c left join &trajectory w on c.GridID=w.GridID
      left join &trajectory b on b.CategoryIndex=w.CategoryIndex and b.TimeFromTransfusion=-60
      where c.TargetKind=2;
  quit;
  %if &syscc>4 or &syserr>4 %then %do; %let RBC_LCPU_STATUS=LCPU_WORKING_SAS_FAILURE; %return; %end;
  %if &n ne %eval(1441*&k) or &bad ne 0 %then %do; %let RBC_LCPU_STATUS=WORKING_CHANGES_CHANGED; %return; %end;
  %let n=-1; %let bad=1;
  proc sql noprint;
    select count(*),coalesce(sum(missing(c.TargetIndex) or c.ContrastStatus ne w.ContrastStatus or
        c.NumericStatus ne w.NumericStatus or w.NumericStatus ne 'COMPUTED' or
        nmiss(c.Estimate,w.Estimate)>0 or abs(c.Estimate-w.Estimate)>1e-8*max(1,abs(w.Estimate))),0)
      into :n trimmed,:bad trimmed
      from &targets w left join &targets c
        on c.TargetKind=2 and c.TimeFromTransfusion=60 and c.CategoryIndexA=w.CategoryIndexA
      where w.TargetKind=3;
  quit;
  %if &syscc>4 or &syserr>4 %then %let RBC_LCPU_STATUS=LCPU_WORKING_SAS_FAILURE;
  %else %if &n ne &k or &bad ne 0 %then %let RBC_LCPU_STATUS=ENDPOINT_DUPLICATE_MISMATCH;
  %else %let RBC_LCPU_STATUS=PASS;
%mend;

%macro rbc_lcpu_unavailable_table(targets=,certificate=,out=,expected=);
  %global RBC_LCPU_STATUS;
  %local n;
  %let RBC_LCPU_STATUS=NOT_COMPLETED; %let n=-1;
  proc sql;
    create table &out as
    select t.TargetIndex,t.TargetKind,t.GridID,t.TargetID,t.TargetRole,
      t.NumericStatus as UnavailableReason length=32,
      t.ContrastStatus as NativeContrastStatus,
      c.Denominator,c.AbsError,c.RelativeErrorUpper,c.IdealRelativeErrorUpper,c.Resolved
    from &targets t inner join &certificate c on t.TargetIndex=c.TargetIndex
    where t.NumericStatus='MOMENT_PRECISION_UNRESOLVED'
    order by t.TargetIndex;
    select count(*) into :n trimmed from &out;
  quit;
  %if &syscc>4 or &syserr>4 or &n ne &expected %then %let RBC_LCPU_STATUS=UNAVAILABLE_BINDING_FAILED;
  %else %let RBC_LCPU_STATUS=PASS;
%mend;

%macro rbc_cr2_holm_guard(pairwise=,npairs=);
  %global RBC_HOLM_GUARD_STATUS;
  %local n bad;
  %let RBC_HOLM_GUARD_STATUS=NOT_COMPLETED; %let n=-1; %let bad=1;
  proc sql noprint;
    select count(*),coalesce(sum(NumericStatus ne 'COMPUTED' or ContrastStatus ne 0 or
        missing(Probt) or Probt<0 or Probt>1),0)
      into :n trimmed,:bad trimmed from &pairwise;
  quit;
  %if &syscc>4 or &syserr>4 %then %let RBC_HOLM_GUARD_STATUS=HOLM_GUARD_SAS_FAILURE;
  %else %if &n ne &npairs or &bad ne 0 %then %let RBC_HOLM_GUARD_STATUS=HOLM_INPUT_INVALID;
  %else %let RBC_HOLM_GUARD_STATUS=PASS;
%mend;
%macro rbc_cr2_integration_reject(reason=);
  %global RBC_CR2_INTEGRATION_OK RBC_CR2_INTEGRATION_REASON;
  %let RBC_CR2_INTEGRATION_OK=0; %let RBC_CR2_INTEGRATION_REASON=&reason;
  %put NOTE: RBC_CR2_INTEGRATION_STATUS &reason;
%mend;
%macro rbc_mf_saved_integration(model_lib=,job_id=,saved_cr2=,
                               outlib=,prefix=,scope=SYNTHETIC_DATA_ONLY,alpha=.05,certificate_hash=,
                               scalar_policy=STRICT);
%local bad p k nrows nperson runid fitid xvars i names members member status nactive npairs qexpected idfields nids j fld expected_cohort owns_contrasts bind_roles numerical_ready _rbc_iml_cpu
       lcu cr2protocol nunavail badu lch report_k original_npairs;
%global RBC_CR2_INTEGRATION_OK RBC_CR2_INTEGRATION_REASON;
%let RBC_CR2_INTEGRATION_OK=0; %let RBC_CR2_INTEGRATION_REASON=NOT_COMPLETED;
%let owns_contrasts=0; %let numerical_ready=0; %let nunavail=0; %let badu=0;
%let report_k=5;
%if %length(%superq(certificate_hash)) ne 64 %then %do;
  %rbc_cr2_integration_reject(reason=CERTIFICATE_SOURCE_HASH_REQUIRED); %return;
%end;
%if %sysfunc(prxmatch(%str(/^[0-9a-f]{64}$/),%superq(certificate_hash))) ne 1 %then %do;
  %rbc_cr2_integration_reject(reason=CERTIFICATE_SOURCE_HASH_INVALID); %return;
%end;
 
%if %superq(scalar_policy)=STRICT %then %do;
  %let lcu=0; %let cr2protocol=RBC_CR2_MONDAY_FRIDAY_V1;
%end;
%else %if %superq(scalar_policy)=LEVEL_CHANGE_PRECISION_UNAVAILABLE_V1 %then %do;
  %let lcu=1; %let cr2protocol=RBC_CR2_MONDAY_FRIDAY_LCPU_V1;
%end;
%else %do;
  %rbc_cr2_integration_reject(reason=SCALAR_POLICY_INVALID); %return;
%end;
%if %superq(scope) ne SYNTHETIC_DATA_ONLY and %superq(scope) ne LOCAL_SAMPLE_MODEL_INFERENCE and %superq(scope) ne FULL_COHORT_MODEL_INFERENCE %then %do;
  %rbc_cr2_integration_reject(reason=INFERENCE_SCOPE_INVALID); %return;
%end;
%if %length(%superq(prefix))<1 or %length(%superq(prefix))>9 or
    not %sysfunc(nvalid(&prefix,V7)) or not %sysfunc(nvalid(&job_id,V7)) or
    not %sysfunc(nvalid(&model_lib,V7)) or not %sysfunc(nvalid(&outlib,V7)) %then %do;
  %rbc_cr2_integration_reject(reason=INVALID_NAMES); %return;
%end;
proc sql noprint;
  select count(*) into :bad trimmed from dictionary.tables
  where libname=upcase("&outlib") and substr(memname,1,length("&prefix._"))=upcase("&prefix._");
quit;
%if &bad ne 0 %then %do; %rbc_cr2_integration_reject(reason=TARGET_EXISTS); %return; %end;

%if %sysfunc(exist(work._rbc_cr2_contrasts,DATA)) or
    %sysfunc(exist(work._rbc_cr2_contrasts,VIEW)) %then %do;
  %rbc_cr2_integration_reject(reason=SCRATCH_TARGET_EXISTS); %return;
%end;
%let members=identity job_status fitmetadata solution covparms columns column_scale score_design anchor_design categories cat_availability family_plan contrast_plan trajectory;
%do i=1 %to %sysfunc(countw(&members));
  %let member=%scan(&members,&i);
  %if not %sysfunc(exist(&model_lib..&job_id._&member)) %then %do;
    %rbc_cr2_integration_reject(reason=WORKING_ARCHIVE_MISSING); %return;
  %end;
%end;
%let expected_cohort=synthetic;
%if %superq(scope)=LOCAL_SAMPLE_MODEL_INFERENCE %then %let expected_cohort=development_sample;
%else %if %superq(scope)=FULL_COHORT_MODEL_INFERENCE %then %let expected_cohort=full_cohort;
proc sql noprint;
  select count(*),sum(CohortMode ne "&expected_cohort" or missing(RunId) or missing(FitId))
    into :nrows trimmed,:bad trimmed from &model_lib..&job_id._identity;
  select RunId,FitId into :runid trimmed,:fitid trimmed from &model_lib..&job_id._identity;
quit;
%if &nrows ne 1 or &bad ne 0 %then %do; %rbc_cr2_integration_reject(reason=WORKING_IDENTITY_SCOPE); %return; %end;

proc sql noprint;
  select upcase(name) into :idfields separated by ' ' from dictionary.columns
  where libname=upcase("&model_lib") and memname=upcase("&job_id._identity");
quit;
%let nids=%sysfunc(countw(&idfields));
%do i=1 %to %sysfunc(countw(&members));
  %let member=%scan(&members,&i);
  proc sql noprint;
    select count(*) into :bad trimmed from dictionary.columns
    where libname=upcase("&model_lib") and memname=upcase("&job_id._&member")
      and findw("&idfields",strip(upcase(name)),' ')>0;
  quit;
  %if &bad ne &nids %then %do;
    %rbc_cr2_integration_reject(reason=WORKING_ARCHIVE_IDENTITY_SCHEMA); %return;
  %end;
  %let bad=0;
  data _null_;
    if _n_=1 then set &model_lib..&job_id._identity(keep=&idfields rename=(
      %do j=1 %to &nids; %let fld=%scan(&idfields,&j); &fld=_C24_&fld %end;
    ));
    set &model_lib..&job_id._&member(keep=&idfields);
    %do j=1 %to &nids;
      %let fld=%scan(&idfields,&j);
      if &fld ne _C24_&fld then call symputx('bad',1,'L');
    %end;
  run;
  %if &syscc>4 or &syserr>4 %then %do;
    %rbc_cr2_integration_reject(reason=WORKING_IDENTITY_CHECK_FAILURE); %return;
  %end;
  %if &bad ne 0 %then %do;
    %rbc_cr2_integration_reject(reason=WORKING_ARCHIVE_IDENTITY); %return;
  %end;
%end;

proc sql noprint;
  select count(*),sum(JobStatus ne 'FIT_CHECKS_PASSED' or FitAttempted ne 1)
    into :nrows trimmed,:bad trimmed from &model_lib..&job_id._job_status;
quit;
%if &nrows ne 1 or &bad ne 0 %then %do; %rbc_cr2_integration_reject(reason=WORKING_FIT_NOT_COMPLETE); %return; %end;
proc sql noprint;
  select N_DesignColumns,N_Categories,N_Used,N_Patients
    into :p trimmed,:k trimmed,:nrows trimmed,:nperson trimmed from &model_lib..&job_id._fitmetadata;
  select count(*),coalesce(sum(Active),0) into :nactive trimmed,:npairs trimmed
    from &model_lib..&job_id._contrast_plan where ContrastType='PAIRWISE';
quit;
%if &p<1 or &k<1 or &npairs ne %eval(&k*(&k-1)/2) %then %do;
  %rbc_cr2_integration_reject(reason=FROZEN_FAMILY_CARDINALITY); %return;
%end;

%let original_npairs=&npairs;
%let npairs=10;
%let qexpected=%eval(2*1441*&report_k+&report_k+&npairs);
proc sql noprint;
  select count(*),coalesce(sum(FactorName ne 'wdy_donation'),1)
    into :nactive trimmed,:bad trimmed from &model_lib..&job_id._family_plan;
quit;
%if &syscc>4 or &syserr>4 or &nactive ne 1 or &bad ne 0 %then %do;
  %rbc_cr2_integration_reject(reason=MONDAY_FRIDAY_FACTOR_REQUIRED); %return;
%end;
%let xvars=; %let names=;
%do i=1 %to &p; %let xvars=&xvars RBCX&i; %let names=&names "RBCX&i"; %end;
data &outlib..&prefix._identity;
  length Scope $32 CovarianceMethod $40 ScalarDFMethod $40 JointDFMethod $16
    WorkingTarget $48 CR2Protocol $40 CR2ArchiveID $12 DFMethod $16 InferenceStatus $32
    CalibrationDomain $40 StructuralCertificate $40 AmendmentID $64
    AmendmentTiming $32 TargetSetID $128 ReportingReference $16
    ReportingSchema $40 TargetRecipeSHA256 MultiplicitySHA256 $64;
  set &model_lib..&job_id._identity(rename=(DFMethod=WorkingDFMethod
    InferenceStatus=WorkingInferenceStatus BindingVersion=WorkingBindingVersion));
  Scope="&scope"; CovarianceMethod='GLS_WHITENED_CR2';
  AmendmentID='MONDAY_FRIDAY_REPORTING_AMENDMENT';
  AmendmentTiming='POST_START_REPORTING_AMENDMENT';
  TargetSetID=cats(upcase("&job_id"),'_MONDAY_FRIDAY_V1_eefab4e58bd5'); ReportingReference='MONDAY';
  ReportingSchema='RBC_MONDAY_FRIDAY_COMPANION_V1';
  TargetRecipeSHA256='eefab4e58bd55d5def4180117696cc4ecd9ae62faeaa1f42380032efdf3da43d';
  MultiplicitySHA256='801e3333cc8c9c0961ca23b2359b82ee45518556f2d392dcd04f5221048ede93';
  OriginalObservedCategories=&k; ReportingCategories=&report_k;
  CalibrationDomain='FIXED_PREDECLARED_TARGET_SPAN'; StructuralCertificate='RAW_LITERAL_SUPPORT_V1';
  TargetCalibrationVerified=0; AllCoefficientsCalibrated=0;
  ScalarDFMethod='CONTRAST_SATTERTHWAITE'; JointDFMethod='HTZ';
  WorkingTarget='FROZEN_REML_RANDOM_INTERCEPT_IID'; CR2Protocol="&cr2protocol";
  CR2ArchiveID="&prefix"; DFMethod='SATTERTHWAITE'; InferenceStatus='CR2_VALIDATION_PENDING'; BindingVersion=3;
run;
data &outlib..&prefix._cat_availability;
  set &model_lib..&job_id._cat_availability(keep=CategoryCode CategoryIndex Available AvailabilityReason);
  if CategoryCode in (2,3,4,5,6);
run;
proc sql noprint;
  select count(*),coalesce(sum(Available ne 1 or missing(CategoryIndex)),1)
    into :nactive trimmed,:bad trimmed from &outlib..&prefix._cat_availability;
quit;
%if &syscc>4 or &syserr>4 or &nactive ne 5 or &bad ne 0 %then %do;
  %rbc_cr2_integration_reject(reason=MONDAY_FRIDAY_CATEGORIES_UNAVAILABLE); %goto finish;
%end;
data &outlib..&prefix._family_plan;
  length FamilyID OriginalFamilyID $128 FreezeStage $32 PAdjustment $40;
  set &model_lib..&job_id._family_plan(keep=FamilyID FamilyRole FactorName Model VitalCode PlannedCategories AvailableCategories PlannedPairs ActivePairs PAdjustment CIAdjustment FreezeStage PlanVersion);
  OriginalFamilyID=FamilyID; FamilyID=cats(upcase("&job_id"),'_HOLM10_V1_801e3333cc8c');
  PlannedCategories=5; AvailableCategories=5; PlannedPairs=10; ActivePairs=10;
  PAdjustment='Holm within amended fixed family10';
  FreezeStage='POST_START_AMENDMENT'; PlanVersion=2;
run;
data &outlib..&prefix._contrast_plan;
  length ContrastID OriginalContrastID $40 FamilyID $128;
  set &model_lib..&job_id._contrast_plan(keep=ContrastID ContrastType CategoryCodeA CategoryCodeB CategoryIndexA CategoryIndexB Planned Active ExclusionReason FamilyID BeforeMinute AfterMinute);
  if CategoryCodeA in (2,3,4,5,6) and
     (ContrastType='WITHIN' or (ContrastType='PAIRWISE' and CategoryCodeB in (2,3,4,5,6)));
  OriginalContrastID=ContrastID; ContrastID=cats('MF1.',OriginalContrastID);
  if ContrastType='PAIRWISE' then FamilyID=cats(upcase("&job_id"),'_HOLM10_V1_801e3333cc8c');
run;

 
proc sql;
  create table &outlib..&prefix._working_target as select
    max(case when CovParm='Intercept' then Estimate else . end) as Tau2,
    max(case when CovParm='Residual' then Estimate else . end) as Sigma2,
    &alpha as Alpha, count(*) as ComponentCount,
    sum(CovParm='Intercept') as RIComponents, sum(CovParm='Residual') as ResidualComponents
    from &model_lib..&job_id._covparms;
quit;
%let bad=0;
data _null_;
  set &outlib..&prefix._working_target;
  if ComponentCount ne 2 or RIComponents ne 1 or ResidualComponents ne 1 or
     nmiss(Tau2,Sigma2,Alpha)>0 or Tau2<0 or Sigma2<=0 or Alpha<=0 or Alpha>=1 then call symputx('bad',1,'L');
run;
%if &bad ne 0 %then %do; %rbc_cr2_integration_reject(reason=FROZEN_VARIANCE_SCHEMA); %goto finish; %end;

%let _rbc_iml_cpu=%sysfunc(getoption(cpucount,keyword));
options cpucount=1;
proc iml;
  %rbc_cr2_iml_modules;
  cr2rc=repeat(' ',1,64); cr2rc='PASS';
  start c24Targets(dummy) global(cr2rc);
    use &model_lib..&job_id._score_design;
      read all var {GridID CategoryIndex CategoryCode TimeFromTransfusion} into keys;
      read all var {&xvars} into score;
    close &model_lib..&job_id._score_design;
    use &model_lib..&job_id._anchor_design;
      read all var {AnchorID CategoryIndex CategoryCode TimeFromTransfusion} into anchors;
      read all var {&xvars} into anchorX;
    close &model_lib..&job_id._anchor_design;
    if nrow(score)^=1441*&k | nrow(anchorX)^=9*&k | countmiss(score)+countmiss(anchorX)>0 then do;
      cr2rc='SCORING_DESIGN_CARDINALITY'; return;
    end;
    times={-720 -660 -360 -60 0 60 360 660 720};
    originalCodes=j(&k,1,.);
    do cat=1 to &k;
      rows=((cat-1)*1441+1):(cat*1441); ar=((cat-1)*9+1):(cat*9);
      if any(keys[rows,1]^=rows`) | any(keys[rows,2]^=cat) |
         any(keys[rows,4]^=(-720:720)`) | any(anchors[ar,2]^=cat) |
         any(anchors[ar,4]^=times`) | any(keys[rows,3]^=anchors[ar[1],3]) then do;
        cr2rc='SCORING_DESIGN_KEYS'; return;
      end;
      originalCodes[cat]=keys[rows[1],3];
    end;
    if countmiss(originalCodes)>0 | any(originalCodes<1) | any(originalCodes>7) |
       any(originalCodes^=round(originalCodes)) | ncol(unique(originalCodes))^=&k then do;
      cr2rc='MONDAY_FRIDAY_ORIGINAL_CATEGORY_MAP'; return;
    end;
    reportCodes={2 3 4 5 6}; reportIndex=j(1,&report_k,.);
    selectedAnchors=j(9*&report_k,&p,0);
    do ri=1 to &report_k;
      found=loc(originalCodes=reportCodes[ri]);
      if ncol(found)^=1 then do; cr2rc='MONDAY_FRIDAY_CATEGORIES_UNAVAILABLE'; return; end;
      reportIndex[ri]=found[1]; cat=found[1];
      selectedAnchors[((ri-1)*9+1):(ri*9),]=anchorX[((cat-1)*9+1):(cat*9),];
    end;
    targetX=j(&qexpected,&p,0); meta=j(&qexpected,8,.); pos=0;
    do kind=1 to 2;
      do ri=1 to &report_k;
        cat=reportIndex[ri];
        do gi=(cat-1)*1441+1 to cat*1441;
          pos=pos+1; targetX[pos,]=score[gi,];
          if kind=2 then targetX[pos,]=targetX[pos,]-score[(cat-1)*1441+661,];
          meta[pos,]=pos||kind||keys[gi,1]||cat||.||keys[gi,4]||keys[gi,3]||.;
        end;
      end;
    end;
    change=j(&report_k,&p,0);
    do ri=1 to &report_k;
      cat=reportIndex[ri];
      change[ri,]=score[(cat-1)*1441+781,]-score[(cat-1)*1441+661,];
      pos=pos+1; targetX[pos,]=change[ri,];
      meta[pos,]=pos||3||.||cat||.||60||reportCodes[ri]||.;
    end;
    do ra=1 to &report_k; do rb=ra+1 to &report_k;
      pos=pos+1; targetX[pos,]=change[ra,]-change[rb,];
      meta[pos,]=pos||4||.||reportIndex[ra]||reportIndex[rb]||60||reportCodes[ra]||reportCodes[rb];
    end; end;
    if pos^=&qexpected then do; cr2rc='TARGET_FAMILY_CARDINALITY'; return; end;
    
    call svd(spanU,spanS,spanV,selectedAnchors`);
    keep=loc(spanS>1e-10*max(spanS)); spanRows=spanU[,keep]`; h=nrow(spanRows);
    if h<1 | h>7*&report_k then do; cr2rc='SCORING_SPAN_DIMENSION'; return; end;
    reconstruction=targetX-targetX*spanRows`*spanRows;
    do ci=1 to nrow(targetX);
      norm=cr2Norm(targetX[ci,]); err=cr2Norm(reconstruction[ci,]);
      if (norm=0 & err^=0) | (norm>0 & err>2e-8*norm) then do;
        cr2rc='TARGET_OUTSIDE_ANCHOR_SPAN'; return;
      end;
    end;
    spanLong=j(h*&p,3,0); pos=0;
    do rr=1 to h; do cc=1 to &p;
      pos=pos+1; spanLong[pos,]=rr||cc||spanRows[rr,cc];
    end; end;
    targetWide=(1:&qexpected)`||targetX;
    create &outlib..&prefix._target_design from targetWide[colname={'TargetIndex' &names}]; append from targetWide; close &outlib..&prefix._target_design;
    create &outlib..&prefix._target_keys from meta[colname={'TargetIndex' 'TargetKind' 'GridID' 'CategoryIndexA' 'CategoryIndexB' 'TimeFromTransfusion' 'CategoryCodeA' 'CategoryCodeB'}]; append from meta; close &outlib..&prefix._target_keys;
    create &outlib..&prefix._span from spanLong[colname={'Span' 'Parameter' 'Weight'}]; append from spanLong; close &outlib..&prefix._span;
    jointX=j(7*(&report_k-1),&p+4,0); pos=0; reference=reportIndex[1];
    do ri=2 to &report_k;
      cat=reportIndex[ri];
      pos=pos+1; jointX[pos,]=1||(ri-1)||cat||.||(change[ri,]-change[1,]);
    end;
    constraint=0;
    do ri=2 to &report_k; do ai=2 to 8;
      if ai^=5 then do;
        cat=reportIndex[ri];pos=pos+1; constraint=constraint+1;
        row=anchorX[(cat-1)*9+ai,]-anchorX[(cat-1)*9+5,]-anchorX[(reference-1)*9+ai,]+anchorX[(reference-1)*9+5,];
        jointX[pos,]=2||constraint||cat||ai||row;
      end;
    end; end;
    create &outlib..&prefix._joint_design from jointX[colname={'TestIndex' 'ConstraintIndex' 'CategoryIndex' 'AnchorIndex' &names}]; append from jointX; close &outlib..&prefix._joint_design;
  finish;
  dummy=0; run c24Targets(dummy);
  call symputx('status',cr2rc,'L');
quit;
options &_rbc_iml_cpu;
%if &syscc>4 or &syserr>4 %then %do; %rbc_cr2_integration_reject(reason=TARGET_SAS_FAILURE); %goto finish; %end;
%if &status ne PASS %then %do; %rbc_cr2_integration_reject(reason=&status); %goto finish; %end;
%let owns_contrasts=1;
data work._rbc_cr2_contrasts;
  set &outlib..&prefix._target_design;
  array x[&p] &xvars;
  Contrast=TargetIndex;
  do Parameter=1 to &p; Weight=x[Parameter]; output; end;
  keep Contrast Parameter Weight;
run;

%if not %sysfunc(nvalid(&saved_cr2,V7)) %then %do;
  %rbc_cr2_integration_reject(reason=SAVED_QR_LIBRARY_INVALID); %goto finish;
%end;
%local saved_bad saved_n;
proc sql noprint;
  select count(*),coalesce(sum(qrstatus ne 'PASS' or RunId ne "&runid" or
    FitId ne "&fitid" or Scope ne "&scope"),1)
    into :saved_n trimmed,:saved_bad trimmed from &saved_cr2..&prefix._cs_status;
quit;
%if &syscc>4 or &syserr>4 or &saved_n ne 1 or &saved_bad ne 0 %then %do;
  %rbc_cr2_integration_reject(reason=SAVED_QR_STATUS_BINDING); %goto finish;
%end;
proc sql noprint;
  select count(*),coalesce(sum(RunId ne "&runid" or FitId ne "&fitid" or
    Scope ne "&scope" or StatisticKind ne 'AUGMENTED_QR' or
    ParameterCount ne &p or ClusterCount ne &nperson or ObservationCount ne &nrows),1)
    into :saved_n trimmed,:saved_bad trimmed from &saved_cr2..&prefix._cs_context;
quit;
%if &syscc>4 or &syserr>4 or &saved_n ne 1 or &saved_bad ne 0 %then %do;
  %rbc_cr2_integration_reject(reason=SAVED_QR_CONTEXT_BINDING); %goto finish;
%end;
proc sql noprint;
  select count(*) into :saved_bad trimmed
  from &saved_cr2..&prefix._cs_solution c full join &model_lib..&job_id._solution m
    on c.Parameter=input(substr(strip(m.Effect),5),best32.)
  where missing(c.Parameter) or missing(m.Effect) or c.Estimate ne m.Estimate;
quit;
%if &syscc>4 or &syserr>4 or &saved_bad ne 0 %then %do;
  %rbc_cr2_integration_reject(reason=SAVED_QR_SOLUTION_BINDING); %goto finish;
%end;
data &outlib..&prefix._stream_context;
  if _n_=1 then set &outlib..&prefix._working_target(keep=Tau2 Sigma2 Alpha);
  if _n_=1 then set &model_lib..&job_id._fitmetadata(keep=N_Used ResidualDF);
  set &saved_cr2..&prefix._cs_context(keep=RunId FitId Scope StatisticKind);
  FittedDesignRank=N_Used-ResidualDF;
  drop N_Used ResidualDF;
run;
%rbc_person_cluster_white_stream(wide=&saved_cr2..&prefix._cs_qr,
  support=&saved_cr2..&prefix._cs_support,
  solution=&saved_cr2..&prefix._cs_solution,contrasts=work._rbc_cr2_contrasts,
  span=&outlib..&prefix._span,context=&outlib..&prefix._stream_context,
  outlib=&outlib,prefix=&prefix._si);
%if &syscc>4 or &syserr>4 %then %do; %rbc_cr2_integration_reject(reason=STREAM_SAS_FAILURE); %goto finish; %end;

proc datasets library=work nolist; delete _rbc_cr2_contrasts / memtype=data; quit;
%if %sysfunc(exist(work._rbc_cr2_contrasts,DATA)) %then %do;
  %rbc_cr2_integration_reject(reason=SCRATCH_CLEANUP_FAILED); %goto finish;
%end;
%let owns_contrasts=0;
proc sql noprint; select cr2rc into :status trimmed from &outlib..&prefix._si_status; quit;
%if &status ne PASS %then %do; %rbc_cr2_integration_reject(reason=&status); %goto finish; %end;

proc sql noprint;
 select count(*),sum(CovarianceMethod ne 'GLS_WHITENED_CR2' or
  CalibrationDomain ne 'FIXED_PREDECLARED_TARGET_SPAN' or
  StructuralCertificate ne 'RAW_LITERAL_SUPPORT_V1' or
  TargetCalibrationVerified ne 1 or AllCoefficientsCalibrated ne 0)
 into :nactive trimmed,:bad trimmed from &outlib..&prefix._si_context;
quit;
%if &nactive ne 1 or &bad ne 0 %then %do;
 %rbc_cr2_integration_reject(reason=TARGET_CALIBRATION_CONTEXT_INVALID); %goto finish;
%end;

proc sql noprint;
  select count(*) into :bad trimmed from &outlib..&prefix._si_context s,
    &model_lib..&job_id._fitmetadata w
  where s.DesignRank ne (w.N_Used-w.ResidualDF);
quit;
%if &bad ne 0 %then %do; %rbc_cr2_integration_reject(reason=WORKING_DESIGN_RANK_CHANGED); %goto finish; %end;
proc sql;
  create table &outlib..&prefix._all_targets as
  select t.*,s.ContrastStatus,s.Estimate,s.StdErr,s.DF,s.tValue,s.Probt,s.Lower,s.Upper,
    s.Variance,s.ReferenceVariance
  from &outlib..&prefix._target_keys t left join &outlib..&prefix._si_inference s
    on t.TargetIndex=s.Contrast order by t.TargetIndex;
quit;
%let bad=0; %let badu=0;
data &outlib..&prefix._all_targets;
  length TargetID OriginalTargetID $40 TargetRole $12 NumericStatus $32 PAdjustment $40 CIAdjustment $32 FamilyID $128;
  set &outlib..&prefix._all_targets;
  BaselineMinute=-60; EndpointMinute=60;
  TargetRole=scan('LEVEL CHANGE WITHIN PAIRWISE',TargetKind,' ');
  if TargetKind=1 then TargetID=cats('L_',put(GridID,z8.));
  else if TargetKind=2 then TargetID=cats('C_',put(GridID,z8.));
  else if TargetKind=3 then TargetID=cats('W_',CategoryCodeA);
  else if TargetKind=4 then TargetID=cats('P_',CategoryCodeA,'_',CategoryCodeB);
  OriginalTargetID=TargetID; TargetID=cats('MF1.',OriginalTargetID);
  FamilyID='NONE'; if TargetKind=4 then FamilyID=cats(upcase("&job_id"),'_HOLM10_V1_801e3333cc8c');
  PAdjustment='NONE'; CIAdjustment='None: pointwise'; NumericStatus='COMPUTED';
  if TargetKind=2 and TimeFromTransfusion=-60 then do;
    if ContrastStatus ne 2 then call symputx('bad',1,'L');
    NumericStatus='BASELINE_ZERO'; Estimate=0; StdErr=0; Lower=0; Upper=0;
    Variance=0; ReferenceVariance=0; DF=.; tValue=.; Probt=.;
    CIAdjustment='Deterministic zero';
  end;
  %if &lcu=1 %then %do;

  else if TargetKind in (1,2) and ContrastStatus=4 then do;
    NumericStatus='MOMENT_PRECISION_UNRESOLVED';
    if n(Estimate,StdErr,DF,tValue,Probt,Lower,Upper,Variance,ReferenceVariance)>0 then call symputx('badu',1,'L');
  end;
  %end;
  else if ContrastStatus ne 0 or nmiss(Estimate,StdErr,DF,tValue,Probt,Lower,Upper,Variance,ReferenceVariance)>0
      or StdErr<=0 or Variance<=0 or ReferenceVariance<=0 or DF<1-1e-8 or DF>&nperson*(1+1e-8)
      or Probt<0 or Probt>1 then do;
    NumericStatus='UNSUPPORTED_ACTIVE_TARGET'; call symputx('bad',1,'L');
  end;
run;
%if &bad ne 0 %then %do; %rbc_cr2_integration_reject(reason=UNSUPPORTED_ACTIVE_TARGET); %goto finish; %end;
%if &badu ne 0 %then %do; %rbc_cr2_integration_reject(reason=UNAVAILABLE_TARGET_HAS_UNCERTAINTY); %goto finish; %end;
proc sql noprint;
  select count(*),sum(NumericStatus='BASELINE_ZERO') into :nactive trimmed,:bad trimmed from &outlib..&prefix._all_targets;
quit;
%if &nactive ne &qexpected or &bad ne &report_k %then %do; %rbc_cr2_integration_reject(reason=ACTIVE_TARGET_COMPLETENESS); %goto finish; %end;
 
proc sql noprint;
  select count(*) into :bad trimmed from &outlib..&prefix._all_targets t
  left join &outlib..&prefix._contrast_plan p on t.TargetID=p.ContrastID
  where t.TargetKind in (3,4) and (missing(p.ContrastID) or p.Active ne 1
    or t.CategoryCodeA ne p.CategoryCodeA
    or (t.TargetKind=4 and t.CategoryCodeB ne p.CategoryCodeB));
quit;
%if &bad ne 0 %then %do; %rbc_cr2_integration_reject(reason=ACTIVE_FAMILY_CHANGED); %goto finish; %end;
%if &lcu=1 %then %do;

  %rbc_lcpu_certificate_check(targets=&outlib..&prefix._all_targets,
    certificate=&outlib..&prefix._si_scalar_certificate);
  %if &RBC_LCPU_STATUS ne PASS %then %do; %rbc_cr2_integration_reject(reason=&RBC_LCPU_STATUS); %goto finish; %end;
  %let nunavail=&RBC_LCPU_COUNT;
  %if &nunavail>0 %then %do;
    %let lch=-1;
    proc sql noprint; select SpanDimension into :lch trimmed from &outlib..&prefix._si_context; quit;
    %if &lch<1 or &syscc>4 or &syserr>4 %then %do;
      %rbc_cr2_integration_reject(reason=UNAVAILABLE_INPUT_SCHEMA); %goto finish;
    %end;
    %rbc_lcpu_points(targets=&outlib..&prefix._all_targets,solution=&outlib..&prefix._si_solution,
      design=&outlib..&prefix._target_design,weights=&outlib..&prefix._si_scalar_weights,
      spanrobust=&outlib..&prefix._si_spanrobust,out=&outlib..&prefix._lc_points,p=&p,h=&lch,q=&qexpected);
    %if &RBC_LCPU_STATUS ne PASS %then %do; %rbc_cr2_integration_reject(reason=&RBC_LCPU_STATUS); %goto finish; %end;
    %rbc_lcpu_merge_points(targets=&outlib..&prefix._all_targets,points=&outlib..&prefix._lc_points);
    %if &RBC_LCPU_STATUS ne PASS %then %do; %rbc_cr2_integration_reject(reason=&RBC_LCPU_STATUS); %goto finish; %end;
  %end;
%end;

proc sql noprint;
  select count(*),sum(missing(w.GridID) or nmiss(c.Estimate,w.Predicted)>0 or
    abs(c.Estimate-w.Predicted)>1e-8*max(1,abs(w.Predicted)))
  into :nactive trimmed,:bad trimmed
  from &outlib..&prefix._all_targets c left join &model_lib..&job_id._trajectory w
    on c.GridID=w.GridID where c.TargetKind=1;
quit;
%if &nactive ne %eval(1441*&report_k) or &bad ne 0 %then %do; %rbc_cr2_integration_reject(reason=WORKING_POINTS_CHANGED); %goto finish; %end;
%if &lcu=1 %then %do;
  %rbc_lcpu_working_checks(targets=&outlib..&prefix._all_targets,trajectory=&model_lib..&job_id._trajectory,k=&report_k);
  %if &RBC_LCPU_STATUS ne PASS %then %do; %rbc_cr2_integration_reject(reason=&RBC_LCPU_STATUS); %goto finish; %end;
  %rbc_lcpu_unavailable_table(targets=&outlib..&prefix._all_targets,
    certificate=&outlib..&prefix._si_scalar_certificate,out=&outlib..&prefix._scalar_unavailable,expected=&nunavail);
  %if &RBC_LCPU_STATUS ne PASS %then %do; %rbc_cr2_integration_reject(reason=&RBC_LCPU_STATUS); %goto finish; %end;
%end;
data &outlib..&prefix._levels &outlib..&prefix._changes &outlib..&prefix._within &outlib..&prefix._pairwise;
  set &outlib..&prefix._all_targets;
  if TargetKind=1 then output &outlib..&prefix._levels;
  else if TargetKind=2 then output &outlib..&prefix._changes;
  else if TargetKind=3 then output &outlib..&prefix._within;
  else if TargetKind=4 then output &outlib..&prefix._pairwise;
run;
%rbc_cr2_holm_guard(pairwise=&outlib..&prefix._pairwise,npairs=&npairs);
%if &RBC_HOLM_GUARD_STATUS ne PASS %then %do; %rbc_cr2_integration_reject(reason=&RBC_HOLM_GUARD_STATUS); %goto finish; %end;
proc sort data=&outlib..&prefix._pairwise; by Probt TargetIndex; run;
data &outlib..&prefix._pairwise;
  set &outlib..&prefix._pairwise;
  retain HolmMaximum 0;
  Rank+1; PValue=Probt; PValue_Holm=min(1,max(HolmMaximum,(&npairs-Rank+1)*PValue));
  HolmMaximum=PValue_Holm; PAdjustment='Holm within amended fixed family10';
  drop HolmMaximum;
run;
%local h dim mvars svars;
proc sql noprint;
 select SpanDimension,MomentDimension into :h trimmed,:dim trimmed
 from &outlib..&prefix._si_context;
quit;
%if &k>1 %then %do;
  proc sql noprint;
    select SpanDimension,MomentDimension into :h trimmed,:dim trimmed from &outlib..&prefix._si_context;
  quit;
  %let mvars=; %let svars=;
  %do i=1 %to &dim; %let mvars=&mvars COL&i; %end;
  %do i=1 %to &h; %let svars=&svars COL&i; %end;
  %let names=; %do i=1 %to &p; %let names=&names COL&i; %end;

  %let _rbc_iml_cpu=%sysfunc(getoption(cpucount,keyword));
  options cpucount=1;
  proc iml;
    %rbc_cr2_iml_modules; %rbc_cr2_moment_modules;
    %rbc_moment_error_fast_modules; %rbc_certified_inference_modules;
    cr2rc=repeat(' ',1,64); cr2rc='PASS';
    boundrc=repeat(' ',1,64);boundrc='NOT_STARTED';completed=0;
    start c24Joint(dummy) global(cr2rc,boundrc,completed);
      run bmHost(0);
      if boundrc^='PASS' then do;cr2rc='BOUND_HOST_REJECTED';return;end;
      use &outlib..&prefix._si_moment; read all var {&mvars} into M; close &outlib..&prefix._si_moment;
      use &outlib..&prefix._si_moment_error;read all var {&mvars} into EM;close &outlib..&prefix._si_moment_error;
      use &outlib..&prefix._si_spanbasis; read all var {&names} into CB; close &outlib..&prefix._si_spanbasis;
      use &outlib..&prefix._si_spanrobust; read all var {&svars} into VR; close &outlib..&prefix._si_spanrobust;
      use &outlib..&prefix._si_context; read all var {RoundoffEnvelope} into envelope; close &outlib..&prefix._si_context;
      use &saved_cr2..&prefix._cs_solution; read all var {Parameter Estimate} into sol; close &saved_cr2..&prefix._cs_solution;
      use &outlib..&prefix._joint_design;
        read all var {TestIndex ConstraintIndex} into key; read all var {&xvars} into C;
      close &outlib..&prefix._joint_design;
      beta=j(&p,1,0); do index=1 to nrow(sol); beta[sol[index,1]]=sol[index,2]; end;
      betaNorm=CB*beta;
      call svd(spanU,spanS,spanV,CB`);
      if min(spanS)<=1e-6*max(spanS) then do; cr2rc='ILL_CONDITIONED_SCORE_SPAN'; return; end;
      rightInverse=spanU*diag(1/spanS)*spanV`;
      result=j(2,10,.);certificate=j(2,11,.);nativeJoint={};rankAudit=j(2,5,.);
      do test=1 to 2;
        ix=loc(key[,1]=test); expected=(&report_k-1); if test=2 then expected=6*(&report_k-1);
        if ncol(ix)^=expected | any(key[ix,2]^=(1:expected)`) then do; cr2rc='JOINT_FAMILY_CARDINALITY'; return; end;
        rows=C[ix,]; weights=rows*rightInverse;
        do ci=1 to nrow(rows);
          if cr2Norm(rows[ci,]-weights[ci,]*CB)>2e-8*cr2Norm(rows[ci,]) then do;
            cr2rc='JOINT_OUTSIDE_ARCHIVED_SPAN'; return;
          end;
        end;
        
        squaredAudit=weights#weights; scalesAudit=sqrt(squaredAudit[,+]);
        if min(scalesAudit)<=0 then do; cr2rc='REDUNDANT_CONSTRAINTS'; return; end;
        normalizedAudit=weights/repeat(scalesAudit,1,&h);
        call svd(rankU,rankS,rankV,normalizedAudit`);
        derivedRank=sum(rankS>1e-10*max(rankS));
        admissibleRank=(min(rankS)>1e-6*max(rankS));
        rankAudit[test,]=test||expected||derivedRank||admissibleRank||(min(rankS)/max(rankS));
        create &outlib..&prefix._joint_rank_audit from rankAudit[
          colname={'TestIndex' 'WrittenRows' 'DerivedRank' 'ReferenceAdmissible' 'MinimumRelativeSingularValue'}];
          append from rankAudit;close &outlib..&prefix._joint_rank_audit;
        if derivedRank^=expected | admissibleRank^=1 then do;
          cr2rc='REDUNDANT_CONSTRAINTS'; return;
        end;
        run cr2CertifiedHTZ(weights,j(expected,1,0),i(&h),M,VR,betaNorm,EM,answer,oneCertificate,oneNativeWn);
        if cr2rc^='PASS' then return;
        result[test,]=test||answer;certificate[test,]=test||oneCertificate;
        nativeJoint=nativeJoint//(j(expected,1,test)||(1:expected)`||oneNativeWn);
      end;
      create &outlib..&prefix._joint from result[colname={'TestIndex' 'JointStatus' 'Q' 'Nu' 'DF1' 'DF2' 'Wald' 'FValue' 'ProbF' 'MomentDenominator'}]; append from result; close &outlib..&prefix._joint;
      nativeNames={'TestIndex' 'ConstraintIndex'}||('COL'+strip(char(1:&h)));
      create &outlib..&prefix._joint_weights from nativeJoint[colname=nativeNames];
        append from nativeJoint;close &outlib..&prefix._joint_weights;
      create &outlib..&prefix._joint_certificate from certificate[
        colname={'TestIndex' 'Denominator' 'AbsError' 'RelativeErrorUpper'
          'IdealRelativeErrorUpper' 'Resolved' 'NuLower' 'NuUpper' 'DF2Lower' 'DF2Upper' 'DF2Sign'}];
        append from certificate;close &outlib..&prefix._joint_certificate;
      completed=1;
    finish;
    dummy=0; run c24Joint(dummy);
    if completed^=1 & cr2rc='PASS' then cr2rc='NOT_COMPLETED';
    if boundrc^='PASS' & cr2rc='PASS' then cr2rc='BOUND_JOINT_CERTIFICATE_FAILED';
    call symputx('status',cr2rc,'L');
  quit;
  options &_rbc_iml_cpu;
  %if &syscc>4 or &syserr>4 %then %do; %rbc_cr2_integration_reject(reason=JOINT_SAS_FAILURE); %goto finish; %end;
  %if &status ne PASS %then %do; %rbc_cr2_integration_reject(reason=&status); %goto finish; %end;
%end;
%else %do;
  data &outlib..&prefix._joint_weights;
    length TestIndex ConstraintIndex %do i=1 %to &h;COL&i %end; 8;
    stop;
  run;
  data &outlib..&prefix._joint_certificate;
    length TestIndex Denominator AbsError RelativeErrorUpper IdealRelativeErrorUpper
      Resolved NuLower NuUpper DF2Lower DF2Upper DF2Sign 8;
    stop;
  run;
  data &outlib..&prefix._joint;
    do TestIndex=1 to 2;
      JointStatus=3; Q=0; Nu=.; DF1=.; DF2=.; Wald=.; FValue=.; ProbF=.; MomentDenominator=.; output;
    end;
  run;
%end;
%let bad=0;
data &outlib..&prefix._joint;
  length TestRole $64 NumericStatus $40;
  set &outlib..&prefix._joint;
  if TestIndex=1 then TestRole='MONDAY_FRIDAY_ENDPOINT_CHANGE_EQUALITY';
  else TestRole='MONDAY_FRIDAY_TRAJECTORY_INTERACTION';
  if JointStatus=0 then NumericStatus='COMPUTED';
  else if JointStatus=1 then NumericStatus='LOW_EFFECTIVE_DF';
  else if JointStatus=2 then do;
    NumericStatus='INSUFFICIENT_EFFECTIVE_DF';
    if nmiss(Q,Nu,DF1,DF2,Wald,MomentDenominator)>0 or Nu<=0 or DF2>0 or Q ne DF1
       or not missing(FValue) or not missing(ProbF) then call symputx('bad',1,'L');
  end;
  else if JointStatus=3 and &k=1 then NumericStatus='NOT_APPLICABLE_SINGLE_CATEGORY';
  else if JointStatus=4 and &k>1 then do;
    NumericStatus='MOMENT_PRECISION_UNRESOLVED';
    if nmiss(Q,DF1,MomentDenominator)>0 or Q ne DF1
       or not missing(FValue) or not missing(ProbF) then call symputx('bad',1,'L');
  end;
  else if JointStatus=5 and &k>1 then do;
    NumericStatus='DF2_SIGN_UNRESOLVED';
    if nmiss(Q,Nu,DF1,DF2,Wald,MomentDenominator)>0 or Nu<=0 or Q ne DF1
       or not missing(FValue) or not missing(ProbF) then call symputx('bad',1,'L');
  end;
  else do; NumericStatus='UNSUPPORTED_ACTIVE_JOINT'; call symputx('bad',1,'L'); end;
  if JointStatus in (0,1) and (nmiss(Q,Nu,DF1,DF2,Wald,FValue,ProbF,MomentDenominator)>0
     or DF2<=0 or Q ne DF1 or FValue<0 or ProbF<0 or ProbF>1) then call symputx('bad',1,'L');
run;
%if &bad ne 0 %then %do; %rbc_cr2_integration_reject(reason=UNSUPPORTED_ACTIVE_JOINT); %goto finish; %end;
%if &syscc>4 or &syserr>4 %then %do; %rbc_cr2_integration_reject(reason=FACADE_SAS_FAILURE); %goto finish; %end;
 
data &outlib..&prefix._certificate_context;
  length CertificateProtocol CertificateMethod $40 CertificateScope $80
    ConstructionSourceSHA256 $64 HostProbe $16 WeightProvenance $24 NumericTransport $16;
  set &outlib..&prefix._si_context(keep=SpanDimension MomentDimension);
  CertificateProtocol='RBC_MOMENT_CERTIFICATE_ARCHIVE_V1';
  CertificateMethod='ENTRYWISE_COMPUTED_GEOMETRY_V1';CertificateVersion=1;
  CertificateScope='COMPUTED_H_L_AND_NATIVE_SCORING_WEIGHT_CONTRACTION_ONLY';
  ConstructionSourceSHA256="&certificate_hash";HostProbe='PASS';
  WeightProvenance='NATIVE_BINARY64';NumericTransport='HEX16_IEEE754';
run;
%if &syscc>4 or &syserr>4 %then %do;
  %rbc_cr2_integration_reject(reason=CERTIFICATE_CONTEXT_FAILURE);%goto finish;
%end;
 
%let numerical_ready=1;
%finish:
%if &owns_contrasts=1 %then %do;
  %if %sysfunc(exist(work._rbc_cr2_contrasts,DATA)) %then %do;
    proc datasets library=work nolist; delete _rbc_cr2_contrasts / memtype=data; quit;
  %end;
  %if %sysfunc(exist(work._rbc_cr2_contrasts,DATA)) %then %do;
    %let numerical_ready=0;
    %rbc_cr2_integration_reject(reason=SCRATCH_CLEANUP_FAILED);
  %end;
  %else %let owns_contrasts=0;
%end;
data &outlib..&prefix._status;
  length IntegrationStatus $32 ReasonCode $64;
  IntegrationStatus='REJECTED'; ReasonCode="&RBC_CR2_INTEGRATION_REASON";
run;
%if &numerical_ready=1 and &syscc<=4 and &syserr<=4 %then %do;
  data &outlib..&prefix._identity;
    set &outlib..&prefix._identity;
    InferenceStatus='CR2_CHECKS_PASSED'; TargetCalibrationVerified=1;
  run;
  %let bind_roles=status working_target levels changes within pairwise joint
    cat_availability contrast_plan family_plan si_covariance si_basis si_bread
    si_moment si_spanbasis si_spanrobust si_solution si_context target_keys target_design
    si_moment_error si_scalar_weights si_scalar_certificate joint_weights joint_certificate certificate_context;
  %if &k>1 %then %let bind_roles=&bind_roles joint_design joint_rank_audit;
  %if &lcu=1 %then %let bind_roles=&bind_roles scalar_unavailable;
  %if %sysfunc(exist(&outlib..&prefix._si_root_summary,DATA)) %then
    %let bind_roles=&bind_roles si_root_summary;
  %rbc_fit_bind_outputs(outlib=&outlib,job_id=&prefix,roles=&bind_roles);
  %if &syscc>4 or &syserr>4 %then %do;
    %rbc_cr2_integration_reject(reason=CR2_IDENTITY_BINDING_FAILED);
  %end;
  %else %do;
    data &outlib..&prefix._status;
      set &outlib..&prefix._status;
      IntegrationStatus='CR2_CHECKS_PASSED'; ReasonCode='PASS';
    run;
    %if &syscc>4 or &syserr>4 %then
      %rbc_cr2_integration_reject(reason=CR2_FINAL_STATUS_FAILED);
    %else %do;
      %let RBC_CR2_INTEGRATION_OK=1; %let RBC_CR2_INTEGRATION_REASON=PASS;
    %end;
  %end;
%end;
%mend;



/* Apply the weekday contrasts to the original fit's full target-span covariance. */
%macro rbc_mf_accepted_reuse(model_lib=,job_id=,saved_cr2=,accepted_cr2=,
                               outlib=,prefix=,scope=SYNTHETIC_DATA_ONLY,alpha=.05,certificate_hash=,
                               scalar_policy=STRICT);
%local bad p k nrows nperson runid fitid xvars i names members member status nactive npairs qexpected idfields nids j fld expected_cohort owns_contrasts bind_roles numerical_ready _rbc_iml_cpu
       lcu cr2protocol nunavail badu lch report_k original_npairs;
%global RBC_CR2_INTEGRATION_OK RBC_CR2_INTEGRATION_REASON;
%let RBC_CR2_INTEGRATION_OK=0; %let RBC_CR2_INTEGRATION_REASON=NOT_COMPLETED;
%let owns_contrasts=0; %let numerical_ready=0; %let nunavail=0; %let badu=0;
%let report_k=5;
%if %length(%superq(certificate_hash)) ne 64 %then %do;
  %rbc_cr2_integration_reject(reason=CERTIFICATE_SOURCE_HASH_REQUIRED); %return;
%end;
%if %sysfunc(prxmatch(%str(/^[0-9a-f]{64}$/),%superq(certificate_hash))) ne 1 %then %do;
  %rbc_cr2_integration_reject(reason=CERTIFICATE_SOURCE_HASH_INVALID); %return;
%end;
 
%if %superq(scalar_policy)=STRICT %then %do;
  %let lcu=0; %let cr2protocol=RBC_CR2_MONDAY_FRIDAY_V1;
%end;
%else %if %superq(scalar_policy)=LEVEL_CHANGE_PRECISION_UNAVAILABLE_V1 %then %do;
  %let lcu=1; %let cr2protocol=RBC_CR2_MONDAY_FRIDAY_LCPU_V1;
%end;
%else %do;
  %rbc_cr2_integration_reject(reason=SCALAR_POLICY_INVALID); %return;
%end;
%if %superq(scope) ne SYNTHETIC_DATA_ONLY and %superq(scope) ne LOCAL_SAMPLE_MODEL_INFERENCE and %superq(scope) ne FULL_COHORT_MODEL_INFERENCE %then %do;
  %rbc_cr2_integration_reject(reason=INFERENCE_SCOPE_INVALID); %return;
%end;
%if %length(%superq(prefix))<1 or %length(%superq(prefix))>9 or
    not %sysfunc(nvalid(&prefix,V7)) or not %sysfunc(nvalid(&job_id,V7)) or
    not %sysfunc(nvalid(&model_lib,V7)) or not %sysfunc(nvalid(&outlib,V7)) %then %do;
  %rbc_cr2_integration_reject(reason=INVALID_NAMES); %return;
%end;
proc sql noprint;
  select count(*) into :bad trimmed from dictionary.tables
  where libname=upcase("&outlib") and substr(memname,1,length("&prefix._"))=upcase("&prefix._");
quit;
%if &bad ne 0 %then %do; %rbc_cr2_integration_reject(reason=TARGET_EXISTS); %return; %end;

%if %sysfunc(exist(work._rbc_cr2_contrasts,DATA)) or
    %sysfunc(exist(work._rbc_cr2_contrasts,VIEW)) %then %do;
  %rbc_cr2_integration_reject(reason=SCRATCH_TARGET_EXISTS); %return;
%end;
%let members=identity job_status fitmetadata solution covparms columns column_scale score_design anchor_design categories cat_availability family_plan contrast_plan trajectory;
%do i=1 %to %sysfunc(countw(&members));
  %let member=%scan(&members,&i);
  %if not %sysfunc(exist(&model_lib..&job_id._&member)) %then %do;
    %rbc_cr2_integration_reject(reason=WORKING_ARCHIVE_MISSING); %return;
  %end;
%end;
%let expected_cohort=synthetic;
%if %superq(scope)=LOCAL_SAMPLE_MODEL_INFERENCE %then %let expected_cohort=development_sample;
%else %if %superq(scope)=FULL_COHORT_MODEL_INFERENCE %then %let expected_cohort=full_cohort;
proc sql noprint;
  select count(*),sum(CohortMode ne "&expected_cohort" or missing(RunId) or missing(FitId))
    into :nrows trimmed,:bad trimmed from &model_lib..&job_id._identity;
  select RunId,FitId into :runid trimmed,:fitid trimmed from &model_lib..&job_id._identity;
quit;
%if &nrows ne 1 or &bad ne 0 %then %do; %rbc_cr2_integration_reject(reason=WORKING_IDENTITY_SCOPE); %return; %end;

proc sql noprint;
  select upcase(name) into :idfields separated by ' ' from dictionary.columns
  where libname=upcase("&model_lib") and memname=upcase("&job_id._identity");
quit;
%let nids=%sysfunc(countw(&idfields));
%do i=1 %to %sysfunc(countw(&members));
  %let member=%scan(&members,&i);
  proc sql noprint;
    select count(*) into :bad trimmed from dictionary.columns
    where libname=upcase("&model_lib") and memname=upcase("&job_id._&member")
      and findw("&idfields",strip(upcase(name)),' ')>0;
  quit;
  %if &bad ne &nids %then %do;
    %rbc_cr2_integration_reject(reason=WORKING_ARCHIVE_IDENTITY_SCHEMA); %return;
  %end;
  %let bad=0;
  data _null_;
    if _n_=1 then set &model_lib..&job_id._identity(keep=&idfields rename=(
      %do j=1 %to &nids; %let fld=%scan(&idfields,&j); &fld=_C24_&fld %end;
    ));
    set &model_lib..&job_id._&member(keep=&idfields);
    %do j=1 %to &nids;
      %let fld=%scan(&idfields,&j);
      if &fld ne _C24_&fld then call symputx('bad',1,'L');
    %end;
  run;
  %if &syscc>4 or &syserr>4 %then %do;
    %rbc_cr2_integration_reject(reason=WORKING_IDENTITY_CHECK_FAILURE); %return;
  %end;
  %if &bad ne 0 %then %do;
    %rbc_cr2_integration_reject(reason=WORKING_ARCHIVE_IDENTITY); %return;
  %end;
%end;

proc sql noprint;
  select count(*),sum(JobStatus ne 'FIT_CHECKS_PASSED' or FitAttempted ne 1)
    into :nrows trimmed,:bad trimmed from &model_lib..&job_id._job_status;
quit;
%if &nrows ne 1 or &bad ne 0 %then %do; %rbc_cr2_integration_reject(reason=WORKING_FIT_NOT_COMPLETE); %return; %end;
proc sql noprint;
  select N_DesignColumns,N_Categories,N_Used,N_Patients
    into :p trimmed,:k trimmed,:nrows trimmed,:nperson trimmed from &model_lib..&job_id._fitmetadata;
  select count(*),coalesce(sum(Active),0) into :nactive trimmed,:npairs trimmed
    from &model_lib..&job_id._contrast_plan where ContrastType='PAIRWISE';
quit;
%if &p<1 or &k<1 or &npairs ne %eval(&k*(&k-1)/2) %then %do;
  %rbc_cr2_integration_reject(reason=FROZEN_FAMILY_CARDINALITY); %return;
%end;

%let original_npairs=&npairs;
%let npairs=10;
%let qexpected=%eval(2*1441*&report_k+&report_k+&npairs);
proc sql noprint;
  select count(*),coalesce(sum(FactorName ne 'wdy_donation'),1)
    into :nactive trimmed,:bad trimmed from &model_lib..&job_id._family_plan;
quit;
%if &syscc>4 or &syserr>4 or &nactive ne 1 or &bad ne 0 %then %do;
  %rbc_cr2_integration_reject(reason=MONDAY_FRIDAY_FACTOR_REQUIRED); %return;
%end;
%let xvars=; %let names=;
%do i=1 %to &p; %let xvars=&xvars RBCX&i; %let names=&names "RBCX&i"; %end;
data &outlib..&prefix._identity;
  length Scope $32 CovarianceMethod $40 ScalarDFMethod $40 JointDFMethod $16
    WorkingTarget $48 CR2Protocol $40 CR2ArchiveID $12 DFMethod $16 InferenceStatus $32
    CalibrationDomain $40 StructuralCertificate $40 AmendmentID $64
    AmendmentTiming $32 TargetSetID $128 ReportingReference $16
    ReportingSchema $40 TargetRecipeSHA256 MultiplicitySHA256 $64;
  set &model_lib..&job_id._identity(rename=(DFMethod=WorkingDFMethod
    InferenceStatus=WorkingInferenceStatus BindingVersion=WorkingBindingVersion));
  Scope="&scope"; CovarianceMethod='GLS_WHITENED_CR2';
  AmendmentID='MONDAY_FRIDAY_REPORTING_AMENDMENT';
  AmendmentTiming='POST_START_REPORTING_AMENDMENT';
  TargetSetID=cats(upcase("&job_id"),'_MONDAY_FRIDAY_V1_eefab4e58bd5'); ReportingReference='MONDAY';
  ReportingSchema='RBC_MONDAY_FRIDAY_COMPANION_V1';
  TargetRecipeSHA256='eefab4e58bd55d5def4180117696cc4ecd9ae62faeaa1f42380032efdf3da43d';
  MultiplicitySHA256='801e3333cc8c9c0961ca23b2359b82ee45518556f2d392dcd04f5221048ede93';
  OriginalObservedCategories=&k; ReportingCategories=&report_k;
  CalibrationDomain='FIXED_PREDECLARED_TARGET_SPAN'; StructuralCertificate='RAW_LITERAL_SUPPORT_V1';
  TargetCalibrationVerified=0; AllCoefficientsCalibrated=0;
  ScalarDFMethod='CONTRAST_SATTERTHWAITE'; JointDFMethod='HTZ';
  WorkingTarget='FROZEN_REML_RANDOM_INTERCEPT_IID'; CR2Protocol="&cr2protocol";
  CR2ArchiveID="&prefix"; DFMethod='SATTERTHWAITE'; InferenceStatus='CR2_VALIDATION_PENDING'; BindingVersion=3;
run;
data &outlib..&prefix._cat_availability;
  set &model_lib..&job_id._cat_availability(keep=CategoryCode CategoryIndex Available AvailabilityReason);
  if CategoryCode in (2,3,4,5,6);
run;
proc sql noprint;
  select count(*),coalesce(sum(Available ne 1 or missing(CategoryIndex)),1)
    into :nactive trimmed,:bad trimmed from &outlib..&prefix._cat_availability;
quit;
%if &syscc>4 or &syserr>4 or &nactive ne 5 or &bad ne 0 %then %do;
  %rbc_cr2_integration_reject(reason=MONDAY_FRIDAY_CATEGORIES_UNAVAILABLE); %goto finish;
%end;
data &outlib..&prefix._family_plan;
  length FamilyID OriginalFamilyID $128 FreezeStage $32 PAdjustment $40;
  set &model_lib..&job_id._family_plan(keep=FamilyID FamilyRole FactorName Model VitalCode PlannedCategories AvailableCategories PlannedPairs ActivePairs PAdjustment CIAdjustment FreezeStage PlanVersion);
  OriginalFamilyID=FamilyID; FamilyID=cats(upcase("&job_id"),'_HOLM10_V1_801e3333cc8c');
  PlannedCategories=5; AvailableCategories=5; PlannedPairs=10; ActivePairs=10;
  PAdjustment='Holm within amended fixed family10';
  FreezeStage='POST_START_AMENDMENT'; PlanVersion=2;
run;
data &outlib..&prefix._contrast_plan;
  length ContrastID OriginalContrastID $40 FamilyID $128;
  set &model_lib..&job_id._contrast_plan(keep=ContrastID ContrastType CategoryCodeA CategoryCodeB CategoryIndexA CategoryIndexB Planned Active ExclusionReason FamilyID BeforeMinute AfterMinute);
  if CategoryCodeA in (2,3,4,5,6) and
     (ContrastType='WITHIN' or (ContrastType='PAIRWISE' and CategoryCodeB in (2,3,4,5,6)));
  OriginalContrastID=ContrastID; ContrastID=cats('MF1.',OriginalContrastID);
  if ContrastType='PAIRWISE' then FamilyID=cats(upcase("&job_id"),'_HOLM10_V1_801e3333cc8c');
run;

 
proc sql;
  create table &outlib..&prefix._working_target as select
    max(case when CovParm='Intercept' then Estimate else . end) as Tau2,
    max(case when CovParm='Residual' then Estimate else . end) as Sigma2,
    &alpha as Alpha, count(*) as ComponentCount,
    sum(CovParm='Intercept') as RIComponents, sum(CovParm='Residual') as ResidualComponents
    from &model_lib..&job_id._covparms;
quit;
%let bad=0;
data _null_;
  set &outlib..&prefix._working_target;
  if ComponentCount ne 2 or RIComponents ne 1 or ResidualComponents ne 1 or
     nmiss(Tau2,Sigma2,Alpha)>0 or Tau2<0 or Sigma2<=0 or Alpha<=0 or Alpha>=1 then call symputx('bad',1,'L');
run;
%if &bad ne 0 %then %do; %rbc_cr2_integration_reject(reason=FROZEN_VARIANCE_SCHEMA); %goto finish; %end;

%let _rbc_iml_cpu=%sysfunc(getoption(cpucount,keyword));
options cpucount=1;
proc iml;
  %rbc_cr2_iml_modules;
  cr2rc=repeat(' ',1,64); cr2rc='PASS';
  start c24Targets(dummy) global(cr2rc);
    use &model_lib..&job_id._score_design;
      read all var {GridID CategoryIndex CategoryCode TimeFromTransfusion} into keys;
      read all var {&xvars} into score;
    close &model_lib..&job_id._score_design;
    use &model_lib..&job_id._anchor_design;
      read all var {AnchorID CategoryIndex CategoryCode TimeFromTransfusion} into anchors;
      read all var {&xvars} into anchorX;
    close &model_lib..&job_id._anchor_design;
    if nrow(score)^=1441*&k | nrow(anchorX)^=9*&k | countmiss(score)+countmiss(anchorX)>0 then do;
      cr2rc='SCORING_DESIGN_CARDINALITY'; return;
    end;
    times={-720 -660 -360 -60 0 60 360 660 720};
    originalCodes=j(&k,1,.);
    do cat=1 to &k;
      rows=((cat-1)*1441+1):(cat*1441); ar=((cat-1)*9+1):(cat*9);
      if any(keys[rows,1]^=rows`) | any(keys[rows,2]^=cat) |
         any(keys[rows,4]^=(-720:720)`) | any(anchors[ar,2]^=cat) |
         any(anchors[ar,4]^=times`) | any(keys[rows,3]^=anchors[ar[1],3]) then do;
        cr2rc='SCORING_DESIGN_KEYS'; return;
      end;
      originalCodes[cat]=keys[rows[1],3];
    end;
    if countmiss(originalCodes)>0 | any(originalCodes<1) | any(originalCodes>7) |
       any(originalCodes^=round(originalCodes)) | ncol(unique(originalCodes))^=&k then do;
      cr2rc='MONDAY_FRIDAY_ORIGINAL_CATEGORY_MAP'; return;
    end;
    reportCodes={2 3 4 5 6}; reportIndex=j(1,&report_k,.);
    selectedAnchors=j(9*&report_k,&p,0);
    do ri=1 to &report_k;
      found=loc(originalCodes=reportCodes[ri]);
      if ncol(found)^=1 then do; cr2rc='MONDAY_FRIDAY_CATEGORIES_UNAVAILABLE'; return; end;
      reportIndex[ri]=found[1]; cat=found[1];
      selectedAnchors[((ri-1)*9+1):(ri*9),]=anchorX[((cat-1)*9+1):(cat*9),];
    end;
    targetX=j(&qexpected,&p,0); meta=j(&qexpected,8,.); pos=0;
    do kind=1 to 2;
      do ri=1 to &report_k;
        cat=reportIndex[ri];
        do gi=(cat-1)*1441+1 to cat*1441;
          pos=pos+1; targetX[pos,]=score[gi,];
          if kind=2 then targetX[pos,]=targetX[pos,]-score[(cat-1)*1441+661,];
          meta[pos,]=pos||kind||keys[gi,1]||cat||.||keys[gi,4]||keys[gi,3]||.;
        end;
      end;
    end;
    change=j(&report_k,&p,0);
    do ri=1 to &report_k;
      cat=reportIndex[ri];
      change[ri,]=score[(cat-1)*1441+781,]-score[(cat-1)*1441+661,];
      pos=pos+1; targetX[pos,]=change[ri,];
      meta[pos,]=pos||3||.||cat||.||60||reportCodes[ri]||.;
    end;
    do ra=1 to &report_k; do rb=ra+1 to &report_k;
      pos=pos+1; targetX[pos,]=change[ra,]-change[rb,];
      meta[pos,]=pos||4||.||reportIndex[ra]||reportIndex[rb]||60||reportCodes[ra]||reportCodes[rb];
    end; end;
    if pos^=&qexpected then do; cr2rc='TARGET_FAMILY_CARDINALITY'; return; end;
    
    call svd(spanU,spanS,spanV,selectedAnchors`);
    keep=loc(spanS>1e-10*max(spanS)); spanRows=spanU[,keep]`; h=nrow(spanRows);
    if h<1 | h>7*&report_k then do; cr2rc='SCORING_SPAN_DIMENSION'; return; end;
    reconstruction=targetX-targetX*spanRows`*spanRows;
    do ci=1 to nrow(targetX);
      norm=cr2Norm(targetX[ci,]); err=cr2Norm(reconstruction[ci,]);
      if (norm=0 & err^=0) | (norm>0 & err>2e-8*norm) then do;
        cr2rc='TARGET_OUTSIDE_ANCHOR_SPAN'; return;
      end;
    end;
    spanLong=j(h*&p,3,0); pos=0;
    do rr=1 to h; do cc=1 to &p;
      pos=pos+1; spanLong[pos,]=rr||cc||spanRows[rr,cc];
    end; end;
    targetWide=(1:&qexpected)`||targetX;
    create &outlib..&prefix._target_design from targetWide[colname={'TargetIndex' &names}]; append from targetWide; close &outlib..&prefix._target_design;
    create &outlib..&prefix._target_keys from meta[colname={'TargetIndex' 'TargetKind' 'GridID' 'CategoryIndexA' 'CategoryIndexB' 'TimeFromTransfusion' 'CategoryCodeA' 'CategoryCodeB'}]; append from meta; close &outlib..&prefix._target_keys;
    create &outlib..&prefix._span from spanLong[colname={'Span' 'Parameter' 'Weight'}]; append from spanLong; close &outlib..&prefix._span;
    jointX=j(7*(&report_k-1),&p+4,0); pos=0; reference=reportIndex[1];
    do ri=2 to &report_k;
      cat=reportIndex[ri];
      pos=pos+1; jointX[pos,]=1||(ri-1)||cat||.||(change[ri,]-change[1,]);
    end;
    constraint=0;
    do ri=2 to &report_k; do ai=2 to 8;
      if ai^=5 then do;
        cat=reportIndex[ri];pos=pos+1; constraint=constraint+1;
        row=anchorX[(cat-1)*9+ai,]-anchorX[(cat-1)*9+5,]-anchorX[(reference-1)*9+ai,]+anchorX[(reference-1)*9+5,];
        jointX[pos,]=2||constraint||cat||ai||row;
      end;
    end; end;
    create &outlib..&prefix._joint_design from jointX[colname={'TestIndex' 'ConstraintIndex' 'CategoryIndex' 'AnchorIndex' &names}]; append from jointX; close &outlib..&prefix._joint_design;
  finish;
  dummy=0; run c24Targets(dummy);
  call symputx('status',cr2rc,'L');
quit;
options &_rbc_iml_cpu;
%if &syscc>4 or &syserr>4 %then %do; %rbc_cr2_integration_reject(reason=TARGET_SAS_FAILURE); %goto finish; %end;
%if &status ne PASS %then %do; %rbc_cr2_integration_reject(reason=&status); %goto finish; %end;


%if not %sysfunc(nvalid(&saved_cr2,V7)) %then %do;
  %rbc_cr2_integration_reject(reason=SAVED_QR_LIBRARY_INVALID); %goto finish;
%end;
%local saved_bad saved_n;
proc sql noprint;
  select count(*),coalesce(sum(qrstatus ne 'PASS' or RunId ne "&runid" or
    FitId ne "&fitid" or Scope ne "&scope"),1)
    into :saved_n trimmed,:saved_bad trimmed from &saved_cr2..&prefix._cs_status;
quit;
%if &syscc>4 or &syserr>4 or &saved_n ne 1 or &saved_bad ne 0 %then %do;
  %rbc_cr2_integration_reject(reason=SAVED_QR_STATUS_BINDING); %goto finish;
%end;
proc sql noprint;
  select count(*),coalesce(sum(RunId ne "&runid" or FitId ne "&fitid" or
    Scope ne "&scope" or StatisticKind ne 'AUGMENTED_QR' or
    ParameterCount ne &p or ClusterCount ne &nperson or ObservationCount ne &nrows),1)
    into :saved_n trimmed,:saved_bad trimmed from &saved_cr2..&prefix._cs_context;
quit;
%if &syscc>4 or &syserr>4 or &saved_n ne 1 or &saved_bad ne 0 %then %do;
  %rbc_cr2_integration_reject(reason=SAVED_QR_CONTEXT_BINDING); %goto finish;
%end;
proc sql noprint;
  select count(*) into :saved_bad trimmed
  from &saved_cr2..&prefix._cs_solution c full join &model_lib..&job_id._solution m
    on c.Parameter=input(substr(strip(m.Effect),5),best32.)
  where missing(c.Parameter) or missing(m.Effect) or c.Estimate ne m.Estimate;
quit;
%if &syscc>4 or &syserr>4 or &saved_bad ne 0 %then %do;
  %rbc_cr2_integration_reject(reason=SAVED_QR_SOLUTION_BINDING); %goto finish;
%end;
data &outlib..&prefix._stream_context;
  if _n_=1 then set &outlib..&prefix._working_target(keep=Tau2 Sigma2 Alpha);
  if _n_=1 then set &model_lib..&job_id._fitmetadata(keep=N_Used ResidualDF);
  set &saved_cr2..&prefix._cs_context(keep=RunId FitId Scope StatisticKind);
  FittedDesignRank=N_Used-ResidualDF;
  drop N_Used ResidualDF;
run;

%if %superq(job_id) ne %superq(RBC_MF_BOUND_JOB) or not %sysfunc(nvalid(&accepted_cr2,V7)) or
    %superq(certificate_hash) ne %superq(RBC_MF_ORIGINAL_CONSTRUCTION) %then %do;
  %rbc_cr2_integration_reject(reason=ACCEPTED_REUSE_SCOPE); %goto finish;
%end;
%local reuse_roles reuse_role reuse_i;
%let reuse_roles=identity all_targets si_basis si_bread si_covariance si_spanbasis si_spanrobust
  si_moment si_moment_error si_solution si_context si_status si_inference
  si_scalar_weights si_scalar_certificate certificate_context;
%do reuse_i=1 %to %sysfunc(countw(&reuse_roles));
  %let reuse_role=%scan(&reuse_roles,&reuse_i);
  %if not %sysfunc(exist(&accepted_cr2..&prefix._&reuse_role,DATA)) %then %do;
    %rbc_cr2_integration_reject(reason=ACCEPTED_REUSE_MEMBER_MISSING); %goto finish;
  %end;
%end;
proc sql noprint;
 select count(*),coalesce(sum(RunId ne "&runid" or FitId ne "&fitid" or JobID ne "&job_id" or
   Scope ne "&scope" or InferenceStatus ne 'CR2_CHECKS_PASSED' or
   CR2Protocol ne 'RBC_CR2_GLS_WHITE_MODEL_V2_LCPU_V1'),1)
 into :saved_n trimmed,:saved_bad trimmed from &accepted_cr2..&prefix._identity;
quit;
%if &syscc>4 or &syserr>4 or &saved_n ne 1 or &saved_bad ne 0 %then %do;
 %rbc_cr2_integration_reject(reason=ACCEPTED_REUSE_IDENTITY); %goto finish;
%end;
proc sql noprint;
 select count(*),coalesce(sum(ConstructionSourceSHA256 ne "&certificate_hash" or
    CertificateProtocol ne 'RBC_MOMENT_CERTIFICATE_ARCHIVE_V1'),1)
 into :saved_n trimmed,:saved_bad trimmed from &accepted_cr2..&prefix._certificate_context;
quit;
%if &syscc>4 or &syserr>4 or &saved_n ne 1 or &saved_bad ne 0 %then %do;
 %rbc_cr2_integration_reject(reason=ACCEPTED_REUSE_CONSTRUCTION); %goto finish;
%end;
data &outlib..&prefix._reuse_keys;
 length OriginalTargetID $40;
 set &outlib..&prefix._target_keys;
 if TargetKind=1 then OriginalTargetID=cats('L_',put(GridID,z8.));
 else if TargetKind=2 then OriginalTargetID=cats('C_',put(GridID,z8.));
 else if TargetKind=3 then OriginalTargetID=cats('W_',CategoryCodeA);
 else if TargetKind=4 then OriginalTargetID=cats('P_',CategoryCodeA,'_',CategoryCodeB);
 keep TargetIndex OriginalTargetID;
run;
proc sql;
 create table &outlib..&prefix._reuse_map as select k.TargetIndex,k.OriginalTargetID,
    s.TargetIndex as OriginalTargetIndex
 from &outlib..&prefix._reuse_keys k left join &accepted_cr2..&prefix._all_targets s
 on k.OriginalTargetID=s.TargetID order by k.TargetIndex;
quit;
proc sql noprint;
 select count(*),count(distinct TargetIndex),count(distinct OriginalTargetIndex),
   coalesce(sum(missing(OriginalTargetIndex)),1)
 into :saved_n trimmed,:nactive trimmed,:saved_bad trimmed,:bad trimmed
 from &outlib..&prefix._reuse_map;
quit;
%if &syscc>4 or &syserr>4 or &saved_n ne &qexpected or &nactive ne &qexpected or
    &saved_bad ne &qexpected or &bad ne 0 %then %do;
 %rbc_cr2_integration_reject(reason=ACCEPTED_REUSE_TARGET_MAP); %goto finish;
%end;
%let reuse_roles=si_basis si_bread si_covariance si_spanbasis si_spanrobust
 si_moment si_moment_error si_solution si_context si_status;
%do reuse_i=1 %to %sysfunc(countw(&reuse_roles));
 %let reuse_role=%scan(&reuse_roles,&reuse_i);
 data &outlib..&prefix._&reuse_role;set &accepted_cr2..&prefix._&reuse_role;run;
%end;
%if %sysfunc(exist(&accepted_cr2..&prefix._si_root_summary,DATA)) %then %do;
 data &outlib..&prefix._si_root_summary;set &accepted_cr2..&prefix._si_root_summary;run;
%end;
proc sql;
 create table &outlib..&prefix._si_inference as
 select m.TargetIndex as Contrast,s.* from &outlib..&prefix._reuse_map m
 inner join &accepted_cr2..&prefix._si_inference(rename=(Contrast=OriginalContrast)) s
 on m.OriginalTargetIndex=s.OriginalContrast order by Contrast;
 create table &outlib..&prefix._si_scalar_weights as
 select m.TargetIndex,s.* from &outlib..&prefix._reuse_map m
 inner join &accepted_cr2..&prefix._si_scalar_weights(rename=(TargetIndex=OriginalTargetIndex)) s
 on m.OriginalTargetIndex=s.OriginalTargetIndex order by m.TargetIndex;
 create table &outlib..&prefix._si_scalar_certificate as
 select m.TargetIndex,s.* from &outlib..&prefix._reuse_map m
 inner join &accepted_cr2..&prefix._si_scalar_certificate(rename=(TargetIndex=OriginalTargetIndex)) s
 on m.OriginalTargetIndex=s.OriginalTargetIndex order by m.TargetIndex;
quit;
data &outlib..&prefix._si_inference;set &outlib..&prefix._si_inference;drop OriginalContrast;run;
data &outlib..&prefix._si_scalar_weights;set &outlib..&prefix._si_scalar_weights;drop OriginalTargetIndex;run;
data &outlib..&prefix._si_scalar_certificate;set &outlib..&prefix._si_scalar_certificate;drop OriginalTargetIndex;run;
%if &syscc>4 or &syserr>4 %then %do;
 %rbc_cr2_integration_reject(reason=ACCEPTED_REUSE_COPY_FAILURE); %goto finish;
%end;
proc sql noprint; select cr2rc into :status trimmed from &outlib..&prefix._si_status; quit;
%if &status ne PASS %then %do; %rbc_cr2_integration_reject(reason=&status); %goto finish; %end;

proc sql noprint;
 select count(*),sum(CovarianceMethod ne 'GLS_WHITENED_CR2' or
  CalibrationDomain ne 'FIXED_PREDECLARED_TARGET_SPAN' or
  StructuralCertificate ne 'RAW_LITERAL_SUPPORT_V1' or
  TargetCalibrationVerified ne 1 or AllCoefficientsCalibrated ne 0)
 into :nactive trimmed,:bad trimmed from &outlib..&prefix._si_context;
quit;
%if &nactive ne 1 or &bad ne 0 %then %do;
 %rbc_cr2_integration_reject(reason=TARGET_CALIBRATION_CONTEXT_INVALID); %goto finish;
%end;

proc sql noprint;
  select count(*) into :bad trimmed from &outlib..&prefix._si_context s,
    &model_lib..&job_id._fitmetadata w
  where s.DesignRank ne (w.N_Used-w.ResidualDF);
quit;
%if &bad ne 0 %then %do; %rbc_cr2_integration_reject(reason=WORKING_DESIGN_RANK_CHANGED); %goto finish; %end;

proc sql;
 create table &outlib..&prefix._all_targets as select m.TargetIndex,m.OriginalTargetID,s.*
 from &outlib..&prefix._reuse_map m inner join
 &accepted_cr2..&prefix._all_targets(rename=(TargetIndex=OriginalTargetIndex TargetID=AcceptedTargetID)) s
 on m.OriginalTargetIndex=s.OriginalTargetIndex order by m.TargetIndex;
quit;
data &outlib..&prefix._all_targets;
 length TargetID $40 FamilyID $128 PAdjustment $40;
 set &outlib..&prefix._all_targets;
 TargetID=cats('MF1.',OriginalTargetID);FamilyID='NONE';
 if TargetKind=4 then FamilyID=cats(upcase("&job_id"),'_HOLM10_V1_801e3333cc8c');
 PAdjustment='NONE';
 drop OriginalTargetIndex AcceptedTargetID;
run;
proc sql noprint;
 select count(*),coalesce(sum(NumericStatus='BASELINE_ZERO'),0),
 coalesce(sum(TargetKind in (1,2) and ContrastStatus=4),0),
 coalesce(sum(NumericStatus not in ('BASELINE_ZERO','COMPUTED','MOMENT_PRECISION_UNRESOLVED') or
   (TargetKind in (3,4) and (ContrastStatus ne 0 or NumericStatus ne 'COMPUTED'))),1)
 into :nactive trimmed,:bad trimmed,:nunavail trimmed,:badu trimmed
 from &outlib..&prefix._all_targets;
quit;
%if &syscc>4 or &syserr>4 or &nactive ne &qexpected or &bad ne &report_k or &badu ne 0 %then %do;
 %rbc_cr2_integration_reject(reason=ACCEPTED_REUSE_FINAL_TARGETS); %goto finish;
%end;
proc sql noprint;
 select count(*) into :bad trimmed from &outlib..&prefix._all_targets t
 left join &outlib..&prefix._contrast_plan p on t.TargetID=p.ContrastID
 where t.TargetKind in (3,4) and (missing(p.ContrastID) or p.Active ne 1
   or t.CategoryCodeA ne p.CategoryCodeA or (t.TargetKind=4 and t.CategoryCodeB ne p.CategoryCodeB));
quit;
%if &bad ne 0 %then %do; %rbc_cr2_integration_reject(reason=ACTIVE_FAMILY_CHANGED); %goto finish; %end;
%if &lcu=1 %then %do;
 %rbc_lcpu_certificate_check(targets=&outlib..&prefix._all_targets,
   certificate=&outlib..&prefix._si_scalar_certificate);
 %if &RBC_LCPU_STATUS ne PASS or &RBC_LCPU_COUNT ne &nunavail %then %do;
  %rbc_cr2_integration_reject(reason=ACCEPTED_REUSE_SCALAR_CERTIFICATES); %goto finish;
 %end;
%end;
proc sql noprint;
  select count(*),sum(missing(w.GridID) or nmiss(c.Estimate,w.Predicted)>0 or
    abs(c.Estimate-w.Predicted)>1e-8*max(1,abs(w.Predicted)))
  into :nactive trimmed,:bad trimmed
  from &outlib..&prefix._all_targets c left join &model_lib..&job_id._trajectory w
    on c.GridID=w.GridID where c.TargetKind=1;
quit;
%if &nactive ne %eval(1441*&report_k) or &bad ne 0 %then %do; %rbc_cr2_integration_reject(reason=WORKING_POINTS_CHANGED); %goto finish; %end;
%if &lcu=1 %then %do;
  %rbc_lcpu_working_checks(targets=&outlib..&prefix._all_targets,trajectory=&model_lib..&job_id._trajectory,k=&report_k);
  %if &RBC_LCPU_STATUS ne PASS %then %do; %rbc_cr2_integration_reject(reason=&RBC_LCPU_STATUS); %goto finish; %end;
  %rbc_lcpu_unavailable_table(targets=&outlib..&prefix._all_targets,
    certificate=&outlib..&prefix._si_scalar_certificate,out=&outlib..&prefix._scalar_unavailable,expected=&nunavail);
  %if &RBC_LCPU_STATUS ne PASS %then %do; %rbc_cr2_integration_reject(reason=&RBC_LCPU_STATUS); %goto finish; %end;
%end;
data &outlib..&prefix._levels &outlib..&prefix._changes &outlib..&prefix._within &outlib..&prefix._pairwise;
  set &outlib..&prefix._all_targets;
  if TargetKind=1 then output &outlib..&prefix._levels;
  else if TargetKind=2 then output &outlib..&prefix._changes;
  else if TargetKind=3 then output &outlib..&prefix._within;
  else if TargetKind=4 then output &outlib..&prefix._pairwise;
run;
%rbc_cr2_holm_guard(pairwise=&outlib..&prefix._pairwise,npairs=&npairs);
%if &RBC_HOLM_GUARD_STATUS ne PASS %then %do; %rbc_cr2_integration_reject(reason=&RBC_HOLM_GUARD_STATUS); %goto finish; %end;
proc sort data=&outlib..&prefix._pairwise; by Probt TargetIndex; run;
data &outlib..&prefix._pairwise;
  set &outlib..&prefix._pairwise;
  retain HolmMaximum 0;
  Rank+1; PValue=Probt; PValue_Holm=min(1,max(HolmMaximum,(&npairs-Rank+1)*PValue));
  HolmMaximum=PValue_Holm; PAdjustment='Holm within amended fixed family10';
  drop HolmMaximum;
run;
%local h dim mvars svars;
proc sql noprint;
 select SpanDimension,MomentDimension into :h trimmed,:dim trimmed
 from &outlib..&prefix._si_context;
quit;
%if &k>1 %then %do;
  proc sql noprint;
    select SpanDimension,MomentDimension into :h trimmed,:dim trimmed from &outlib..&prefix._si_context;
  quit;
  %let mvars=; %let svars=;
  %do i=1 %to &dim; %let mvars=&mvars COL&i; %end;
  %do i=1 %to &h; %let svars=&svars COL&i; %end;
  %let names=; %do i=1 %to &p; %let names=&names COL&i; %end;

  %let _rbc_iml_cpu=%sysfunc(getoption(cpucount,keyword));
  options cpucount=1;
  proc iml;
    %rbc_cr2_iml_modules; %rbc_cr2_moment_modules;
    %rbc_moment_error_fast_modules; %rbc_certified_inference_modules;
    cr2rc=repeat(' ',1,64); cr2rc='PASS';
    boundrc=repeat(' ',1,64);boundrc='NOT_STARTED';completed=0;
    start c24Joint(dummy) global(cr2rc,boundrc,completed);
      run bmHost(0);
      if boundrc^='PASS' then do;cr2rc='BOUND_HOST_REJECTED';return;end;
      use &outlib..&prefix._si_moment; read all var {&mvars} into M; close &outlib..&prefix._si_moment;
      use &outlib..&prefix._si_moment_error;read all var {&mvars} into EM;close &outlib..&prefix._si_moment_error;
      use &outlib..&prefix._si_spanbasis; read all var {&names} into CB; close &outlib..&prefix._si_spanbasis;
      use &outlib..&prefix._si_spanrobust; read all var {&svars} into VR; close &outlib..&prefix._si_spanrobust;
      use &outlib..&prefix._si_context; read all var {RoundoffEnvelope} into envelope; close &outlib..&prefix._si_context;
      use &saved_cr2..&prefix._cs_solution; read all var {Parameter Estimate} into sol; close &saved_cr2..&prefix._cs_solution;
      use &outlib..&prefix._joint_design;
        read all var {TestIndex ConstraintIndex} into key; read all var {&xvars} into C;
      close &outlib..&prefix._joint_design;
      beta=j(&p,1,0); do index=1 to nrow(sol); beta[sol[index,1]]=sol[index,2]; end;
      betaNorm=CB*beta;
      call svd(spanU,spanS,spanV,CB`);
      if min(spanS)<=1e-6*max(spanS) then do; cr2rc='ILL_CONDITIONED_SCORE_SPAN'; return; end;
      rightInverse=spanU*diag(1/spanS)*spanV`;
      result=j(2,10,.);certificate=j(2,11,.);nativeJoint={};rankAudit=j(2,5,.);
      do test=1 to 2;
        ix=loc(key[,1]=test); expected=(&report_k-1); if test=2 then expected=6*(&report_k-1);
        if ncol(ix)^=expected | any(key[ix,2]^=(1:expected)`) then do; cr2rc='JOINT_FAMILY_CARDINALITY'; return; end;
        rows=C[ix,]; weights=rows*rightInverse;
        do ci=1 to nrow(rows);
          if cr2Norm(rows[ci,]-weights[ci,]*CB)>2e-8*cr2Norm(rows[ci,]) then do;
            cr2rc='JOINT_OUTSIDE_ARCHIVED_SPAN'; return;
          end;
        end;
        
        squaredAudit=weights#weights; scalesAudit=sqrt(squaredAudit[,+]);
        if min(scalesAudit)<=0 then do; cr2rc='REDUNDANT_CONSTRAINTS'; return; end;
        normalizedAudit=weights/repeat(scalesAudit,1,&h);
        call svd(rankU,rankS,rankV,normalizedAudit`);
        derivedRank=sum(rankS>1e-10*max(rankS));
        admissibleRank=(min(rankS)>1e-6*max(rankS));
        rankAudit[test,]=test||expected||derivedRank||admissibleRank||(min(rankS)/max(rankS));
        create &outlib..&prefix._joint_rank_audit from rankAudit[
          colname={'TestIndex' 'WrittenRows' 'DerivedRank' 'ReferenceAdmissible' 'MinimumRelativeSingularValue'}];
          append from rankAudit;close &outlib..&prefix._joint_rank_audit;
        if derivedRank^=expected | admissibleRank^=1 then do;
          cr2rc='REDUNDANT_CONSTRAINTS'; return;
        end;
        run cr2CertifiedHTZ(weights,j(expected,1,0),i(&h),M,VR,betaNorm,EM,answer,oneCertificate,oneNativeWn);
        if cr2rc^='PASS' then return;
        result[test,]=test||answer;certificate[test,]=test||oneCertificate;
        nativeJoint=nativeJoint//(j(expected,1,test)||(1:expected)`||oneNativeWn);
      end;
      create &outlib..&prefix._joint from result[colname={'TestIndex' 'JointStatus' 'Q' 'Nu' 'DF1' 'DF2' 'Wald' 'FValue' 'ProbF' 'MomentDenominator'}]; append from result; close &outlib..&prefix._joint;
      nativeNames={'TestIndex' 'ConstraintIndex'}||('COL'+strip(char(1:&h)));
      create &outlib..&prefix._joint_weights from nativeJoint[colname=nativeNames];
        append from nativeJoint;close &outlib..&prefix._joint_weights;
      create &outlib..&prefix._joint_certificate from certificate[
        colname={'TestIndex' 'Denominator' 'AbsError' 'RelativeErrorUpper'
          'IdealRelativeErrorUpper' 'Resolved' 'NuLower' 'NuUpper' 'DF2Lower' 'DF2Upper' 'DF2Sign'}];
        append from certificate;close &outlib..&prefix._joint_certificate;
      completed=1;
    finish;
    dummy=0; run c24Joint(dummy);
    if completed^=1 & cr2rc='PASS' then cr2rc='NOT_COMPLETED';
    if boundrc^='PASS' & cr2rc='PASS' then cr2rc='BOUND_JOINT_CERTIFICATE_FAILED';
    call symputx('status',cr2rc,'L');
  quit;
  options &_rbc_iml_cpu;
  %if &syscc>4 or &syserr>4 %then %do; %rbc_cr2_integration_reject(reason=JOINT_SAS_FAILURE); %goto finish; %end;
  %if &status ne PASS %then %do; %rbc_cr2_integration_reject(reason=&status); %goto finish; %end;
%end;
%else %do;
  data &outlib..&prefix._joint_weights;
    length TestIndex ConstraintIndex %do i=1 %to &h;COL&i %end; 8;
    stop;
  run;
  data &outlib..&prefix._joint_certificate;
    length TestIndex Denominator AbsError RelativeErrorUpper IdealRelativeErrorUpper
      Resolved NuLower NuUpper DF2Lower DF2Upper DF2Sign 8;
    stop;
  run;
  data &outlib..&prefix._joint;
    do TestIndex=1 to 2;
      JointStatus=3; Q=0; Nu=.; DF1=.; DF2=.; Wald=.; FValue=.; ProbF=.; MomentDenominator=.; output;
    end;
  run;
%end;
%let bad=0;
data &outlib..&prefix._joint;
  length TestRole $64 NumericStatus $40;
  set &outlib..&prefix._joint;
  if TestIndex=1 then TestRole='MONDAY_FRIDAY_ENDPOINT_CHANGE_EQUALITY';
  else TestRole='MONDAY_FRIDAY_TRAJECTORY_INTERACTION';
  if JointStatus=0 then NumericStatus='COMPUTED';
  else if JointStatus=1 then NumericStatus='LOW_EFFECTIVE_DF';
  else if JointStatus=2 then do;
    NumericStatus='INSUFFICIENT_EFFECTIVE_DF';
    if nmiss(Q,Nu,DF1,DF2,Wald,MomentDenominator)>0 or Nu<=0 or DF2>0 or Q ne DF1
       or not missing(FValue) or not missing(ProbF) then call symputx('bad',1,'L');
  end;
  else if JointStatus=3 and &k=1 then NumericStatus='NOT_APPLICABLE_SINGLE_CATEGORY';
  else if JointStatus=4 and &k>1 then do;
    NumericStatus='MOMENT_PRECISION_UNRESOLVED';
    if nmiss(Q,DF1,MomentDenominator)>0 or Q ne DF1
       or not missing(FValue) or not missing(ProbF) then call symputx('bad',1,'L');
  end;
  else if JointStatus=5 and &k>1 then do;
    NumericStatus='DF2_SIGN_UNRESOLVED';
    if nmiss(Q,Nu,DF1,DF2,Wald,MomentDenominator)>0 or Nu<=0 or Q ne DF1
       or not missing(FValue) or not missing(ProbF) then call symputx('bad',1,'L');
  end;
  else do; NumericStatus='UNSUPPORTED_ACTIVE_JOINT'; call symputx('bad',1,'L'); end;
  if JointStatus in (0,1) and (nmiss(Q,Nu,DF1,DF2,Wald,FValue,ProbF,MomentDenominator)>0
     or DF2<=0 or Q ne DF1 or FValue<0 or ProbF<0 or ProbF>1) then call symputx('bad',1,'L');
run;
%if &bad ne 0 %then %do; %rbc_cr2_integration_reject(reason=UNSUPPORTED_ACTIVE_JOINT); %goto finish; %end;
%if &syscc>4 or &syserr>4 %then %do; %rbc_cr2_integration_reject(reason=FACADE_SAS_FAILURE); %goto finish; %end;
 
data &outlib..&prefix._certificate_context;
  length CertificateProtocol CertificateMethod $40 CertificateScope $80
    ConstructionSourceSHA256 $64 HostProbe $16 WeightProvenance $24 NumericTransport $16;
  set &outlib..&prefix._si_context(keep=SpanDimension MomentDimension);
  CertificateProtocol='RBC_MOMENT_CERTIFICATE_ARCHIVE_V1';
  CertificateMethod='ENTRYWISE_COMPUTED_GEOMETRY_V1';CertificateVersion=1;
  CertificateScope='COMPUTED_H_L_AND_NATIVE_SCORING_WEIGHT_CONTRACTION_ONLY';
  ConstructionSourceSHA256="&certificate_hash";HostProbe='PASS';
  WeightProvenance='NATIVE_BINARY64';NumericTransport='HEX16_IEEE754';
run;
%if &syscc>4 or &syserr>4 %then %do;
  %rbc_cr2_integration_reject(reason=CERTIFICATE_CONTEXT_FAILURE);%goto finish;
%end;
 
%let numerical_ready=1;
%finish:
%if &owns_contrasts=1 %then %do;
  %if %sysfunc(exist(work._rbc_cr2_contrasts,DATA)) %then %do;
    proc datasets library=work nolist; delete _rbc_cr2_contrasts / memtype=data; quit;
  %end;
  %if %sysfunc(exist(work._rbc_cr2_contrasts,DATA)) %then %do;
    %let numerical_ready=0;
    %rbc_cr2_integration_reject(reason=SCRATCH_CLEANUP_FAILED);
  %end;
  %else %let owns_contrasts=0;
%end;
data &outlib..&prefix._status;
  length IntegrationStatus $32 ReasonCode $64;
  IntegrationStatus='REJECTED'; ReasonCode="&RBC_CR2_INTEGRATION_REASON";
run;
%if &numerical_ready=1 and &syscc<=4 and &syserr<=4 %then %do;
  data &outlib..&prefix._identity;
    set &outlib..&prefix._identity;
    InferenceStatus='CR2_CHECKS_PASSED'; TargetCalibrationVerified=1;
  run;
  %let bind_roles=status working_target levels changes within pairwise joint
    cat_availability contrast_plan family_plan si_covariance si_basis si_bread
    si_moment si_spanbasis si_spanrobust si_solution si_context target_keys target_design
    si_moment_error si_scalar_weights si_scalar_certificate joint_weights joint_certificate certificate_context;
  %if &k>1 %then %let bind_roles=&bind_roles joint_design joint_rank_audit;
  %if &lcu=1 %then %let bind_roles=&bind_roles scalar_unavailable;
  %if %sysfunc(exist(&outlib..&prefix._si_root_summary,DATA)) %then
    %let bind_roles=&bind_roles si_root_summary;
  
  %local reuse_bind_i reuse_bind_role reuse_drop;
  %let bind_roles=&bind_roles all_targets;
  %do reuse_bind_i=1 %to %sysfunc(countw(&bind_roles));
    %let reuse_bind_role=%scan(&bind_roles,&reuse_bind_i);
    %let reuse_drop=;
    proc sql noprint;
      select o.name into :reuse_drop separated by ' '
      from dictionary.columns o inner join dictionary.columns identity_fields
      on upcase(o.name)=upcase(identity_fields.name)
      where o.libname=upcase("&outlib") and o.memname=upcase("&prefix._&reuse_bind_role")
      and identity_fields.libname=upcase("&outlib") and identity_fields.memname=upcase("&prefix._identity");
    quit;
    %if &syscc>4 or &syserr>4 %then %do;
      %rbc_cr2_integration_reject(reason=REUSE_IDENTITY_METADATA_SCHEMA); %return;
    %end;
    %if %length(%superq(reuse_drop))>0 %then %do;
      data &outlib..&prefix._&reuse_bind_role;
        set &outlib..&prefix._&reuse_bind_role(drop=&reuse_drop);
      run;
      %if &syscc>4 or &syserr>4 %then %do;
        %rbc_cr2_integration_reject(reason=REUSE_IDENTITY_METADATA_COPY); %return;
      %end;
    %end;
  %end;
  %rbc_fit_bind_outputs(outlib=&outlib,job_id=&prefix,roles=&bind_roles);
  %if &syscc>4 or &syserr>4 %then %do;
    %rbc_cr2_integration_reject(reason=CR2_IDENTITY_BINDING_FAILED);
  %end;
  %else %do;
    data &outlib..&prefix._status;
      set &outlib..&prefix._status;
      IntegrationStatus='CR2_CHECKS_PASSED'; ReasonCode='PASS';
    run;
    %if &syscc>4 or &syserr>4 %then
      %rbc_cr2_integration_reject(reason=CR2_FINAL_STATUS_FAILED);
    %else %do;
      %let RBC_CR2_INTEGRATION_OK=1; %let RBC_CR2_INTEGRATION_REASON=PASS;
    %end;
  %end;
%end;
%mend;



/* Create separate coefficient, residual and trajectory derivatives. */

%macro rbc_weekday_stage_candidate(meanpath=,qrpath=,stage=,job_id=,prefix=);
%local p ids bad n nc nr nt;
%if not %sysfunc(prxmatch(%str(/^M[0-9]{4}$/),%superq(job_id))) or
    not %sysfunc(prxmatch(%str(/^C[0-9]{4}$/),%superq(prefix))) or
    %substr(&job_id,2) ne %substr(&prefix,2) or %length(%superq(stage))=0
    %then %abort cancel;
%if not %symexist(RBC_WEEKDAY_CORRECTION_OK) %then %abort cancel;
%if &RBC_WEEKDAY_CORRECTION_OK ne YES %then %abort cancel;
libname ORIGM "&meanpath" access=readonly;
libname ORIGS "&qrpath" access=readonly;
libname CANDM "&stage/models";
libname CANDS "&stage/saved";
data _null_;
 if put(1,hex16.) ne '3FF0000000000000' or put(-2,hex16.) ne 'C000000000000000' then abort cancel;
run;
proc sql noprint;
 select count(*) into :bad trimmed from dictionary.tables where libname in ('CANDM','CANDS');
 select N_DesignColumns into :p trimmed from ORIGM.&job_id._fitmetadata;
 select name into :ids separated by ' ' from dictionary.columns
   where libname='ORIGM' and memname="&job_id._IDENTITY" order by varnum;
quit;
%if &syscc>4 or &syserr>4 or &bad ne 0 or &p<1 or &p>200 %then %abort cancel;
data work._weekday_candidate_vector;
 length OriginalHex CandidateHex AppliedHex $16 OriginalText CandidateText AppliedText $40;
 infile "&stage/exchange/candidate_vector.csv" dsd firstobs=2 lrecl=32767 truncover;
 input Parameter :best32. OriginalText :$40. CandidateText :$40. AppliedText :$40.
       OriginalHex :$16. CandidateHex :$16. AppliedHex :$16.;
 OriginalBeta=input(OriginalHex,hex16.);CandidateBeta=input(CandidateHex,hex16.);
 AppliedChange=input(AppliedHex,hex16.);
 drop OriginalText CandidateText AppliedText;
 if nmiss(Parameter,OriginalBeta,CandidateBeta,AppliedChange)>0 or
    Parameter<1 or Parameter>&p or Parameter ne int(Parameter) then abort cancel;
 if put(OriginalBeta,hex16.) ne OriginalHex or put(CandidateBeta,hex16.) ne CandidateHex or
    put(AppliedChange,hex16.) ne AppliedHex or
    put(CandidateBeta-OriginalBeta,hex16.) ne AppliedHex then abort cancel;
run;
data work._weekday_candidate_rhs;
 length OriginalHex CandidateHex $16 OriginalText CandidateText $40;
 infile "&stage/exchange/candidate_rhs.csv" dsd firstobs=2 lrecl=32767 truncover;
 input RequiredCluster :best32. RequiredRow :best32. OriginalText :$40. CandidateText :$40.
       OriginalHex :$16. CandidateHex :$16.;
 OriginalCross=input(OriginalHex,hex16.);CandidateCross=input(CandidateHex,hex16.);
 drop OriginalText CandidateText;
 if nmiss(RequiredCluster,RequiredRow,OriginalCross,CandidateCross)>0 or
    put(OriginalCross,hex16.) ne OriginalHex or put(CandidateCross,hex16.) ne CandidateHex then abort cancel;
run;
data work._weekday_candidate_trajectory;
 length PredictedHex DeltaHex $16 PredictedText DeltaText $40;
 infile "&stage/exchange/candidate_trajectory.csv" dsd firstobs=2 lrecl=32767 truncover;
 input GridID :best32. RequiredCategoryIndex :best32. RequiredCategoryCode :best32.
       RequiredTime :best32. PredictedText :$40. DeltaText :$40.
       PredictedHex :$16. DeltaHex :$16.;
 CandidatePredicted=input(PredictedHex,hex16.);CandidateDelta=input(DeltaHex,hex16.);
 drop PredictedText DeltaText;
 if nmiss(GridID,RequiredCategoryIndex,RequiredCategoryCode,RequiredTime,CandidatePredicted,CandidateDelta)>0 or
    put(CandidatePredicted,hex16.) ne PredictedHex or put(CandidateDelta,hex16.) ne DeltaHex then abort cancel;
run;
%if &syscc>4 or &syserr>4 %then %abort cancel;
proc sql noprint;
 select count(*),count(distinct Parameter) into :n trimmed,:nc trimmed from work._weekday_candidate_vector;
 select count(*) into :nr trimmed from ORIGS.&prefix._cs_qr;
 select count(*) into :bad trimmed from work._weekday_candidate_rhs;
quit;
%if &n ne &p or &nc ne &p or &bad ne &nr %then %abort cancel;
proc sql noprint;
 select count(*) into :nt trimmed from ORIGM.&job_id._trajectory;
 select count(*),count(distinct GridID) into :n trimmed,:nc trimmed from work._weekday_candidate_trajectory;
quit;
%if &n ne &nt or &nc ne &nt %then %abort cancel;
proc copy in=ORIGM out=CANDM memtype=data;
 select &job_id._identity &job_id._job_status &job_id._fitmetadata &job_id._covparms
        &job_id._columns &job_id._column_scale &job_id._score_design &job_id._anchor_design
        &job_id._categories &job_id._cat_availability &job_id._family_plan &job_id._contrast_plan;
run;
proc copy in=ORIGS out=CANDS memtype=data;
 select &prefix._cs_context &prefix._cs_support &prefix._cs_status;
run;
data CANDS.&prefix._cs_qr;
 set ORIGS.&prefix._cs_qr;
 set work._weekday_candidate_rhs;
 if Cluster ne RequiredCluster or Row ne RequiredRow or put(Cross,hex16.) ne OriginalHex then abort cancel;
 Cross=CandidateCross;
 drop RequiredCluster RequiredRow OriginalCross CandidateCross OriginalHex CandidateHex;
run;
data CANDS.&prefix._cs_solution;
 if 0 then set work._weekday_candidate_vector;
 if _n_=1 then do;
  declare hash coeff(dataset:'work._weekday_candidate_vector');
  coeff.defineKey('Parameter');coeff.defineData('OriginalBeta','CandidateBeta','OriginalHex');coeff.defineDone();
 end;
 set ORIGS.&prefix._cs_solution;
 if coeff.find() ne 0 or put(Estimate,hex16.) ne OriginalHex then abort cancel;
 Estimate=CandidateBeta;
 drop OriginalBeta CandidateBeta AppliedChange OriginalHex CandidateHex AppliedHex;
run;
data CANDM.&job_id._solution;
 if 0 then set work._weekday_candidate_vector;
 if _n_=1 then do;
  declare hash coeff(dataset:'work._weekday_candidate_vector');
  coeff.defineKey('Parameter');coeff.defineData('OriginalBeta','CandidateBeta','OriginalHex');coeff.defineDone();
 end;
 set ORIGM.&job_id._solution(keep=&ids Effect Estimate);
 if substr(upcase(strip(Effect)),1,4) ne 'RBCX' then abort cancel;
 Parameter=input(substr(strip(Effect),5),best32.);
 if coeff.find() ne 0 or put(Estimate,hex16.) ne OriginalHex then abort cancel;
 Estimate=CandidateBeta;
 drop Parameter OriginalBeta CandidateBeta AppliedChange OriginalHex CandidateHex AppliedHex;
run;
data CANDM.&job_id._trajectory;
 if 0 then set work._weekday_candidate_trajectory;
 if _n_=1 then do;
  declare hash points(dataset:'work._weekday_candidate_trajectory');
  points.defineKey('GridID');
  points.defineData('RequiredCategoryIndex','RequiredCategoryCode','RequiredTime','CandidatePredicted','CandidateDelta');
  points.defineDone();
 end;
 set ORIGM.&job_id._trajectory(keep=&ids VitalCode FactorName Model GridID CategoryIndex CategoryCode
                               TimeFromTransfusion Predicted Delta BaselineMinute);
 if points.find() ne 0 or CategoryIndex ne RequiredCategoryIndex or CategoryCode ne RequiredCategoryCode or
    TimeFromTransfusion ne RequiredTime or BaselineMinute ne -60 then abort cancel;
 Predicted=CandidatePredicted;Delta=CandidateDelta;
 drop RequiredCategoryIndex RequiredCategoryCode RequiredTime CandidatePredicted CandidateDelta PredictedHex DeltaHex;
run;
%if &syscc>4 or &syserr>4 %then %abort cancel;
libname ORIGM clear;libname ORIGS clear;libname CANDM clear;libname CANDS clear;
%mend;
