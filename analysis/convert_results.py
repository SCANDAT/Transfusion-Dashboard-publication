"""Create readable decimal CSVs from independently validated local archives."""
from pathlib import Path
import hashlib,json,uuid
from run import file_hash
from validate import archive_hashes
from file_utils import digest,write_once,safe_path
from csv_formats import convert_csv,schema_chars,convert_loess_file

def require(ok,code):
    if not ok:raise ValueError(code)

def convert_step(step):
    context_bytes=(step/'context.json').read_bytes();receipt_bytes=(step/'validation.json').read_bytes()
    context=json.loads(context_bytes.decode('utf-8-sig'));receipt=json.loads(receipt_bytes.decode('utf-8-sig'))
    context_file_hash=hashlib.sha256(context_bytes).hexdigest();receipt_file_hash=hashlib.sha256(receipt_bytes).hexdigest()
    require(receipt['contextHash']==digest(context),'VALIDATION_CONTEXT_CHANGED')
    result=receipt['validation'];status=result['status']
    require(status in {'VALIDATED','EXPECTED_UNAVAILABLE_VALIDATED','EXPECTED_INFERENCE_UNAVAILABLE_VALIDATED'},'VALIDATION_REQUIRED')
    require(context['task'] in {'MODEL','REPORT','LOESS'},'UNSUPPORTED_CONVERSION_STEP')
    destination=step/'decimal_csv'
    sources=[];validated_sources={}
    if context['task']=='MODEL':
        job=context['job']['JobID'];prefix='C'+job[1:]
        for folder,group in [('model_csv','working'),('inference_csv','robust')]:
            require(archive_hashes(step/folder)==result['inputHashes'][group],'VALIDATED_INPUT_CHANGED')
            for p in sorted((step/folder).glob('*.csv')):
                if group=='working':kind='WORKING';role=p.stem[len(job)+1:]
                elif p.stem.startswith(prefix+'_iu_'):kind='INFERENCE_UNAVAILABLE';role=p.stem[len(prefix)+4:]
                else:kind='WHITE';role=p.stem[len(prefix)+1:]
                sources.append((p,folder,kind,role));validated_sources[(folder,p.name)]=result['inputHashes'][group][p.name]
    else:
        require(archive_hashes(step/'csv')==result['inputHashes'],'VALIDATED_INPUT_CHANGED')
        kind='LOESS' if context['task']=='LOESS' else 'REPORT'
        sources=[(p,'csv',kind,p.stem) for p in sorted((step/'csv').glob('*.csv'))]
        validated_sources={('csv',name):value for name,value in result['inputHashes'].items()}

    def check_bindings():
        if context['task']=='MODEL':
            require({'working':archive_hashes(step/'model_csv'),'robust':archive_hashes(step/'inference_csv')}==result['inputHashes'],'VALIDATED_INPUT_CHANGED')
        else:require(archive_hashes(step/'csv')==result['inputHashes'],'VALIDATED_INPUT_CHANGED')
        require(file_hash(step/'context.json')==context_file_hash,'CONVERSION_CONTEXT_CHANGED')
        require(file_hash(step/'validation.json')==receipt_file_hash,'CONVERSION_VALIDATION_CHANGED')

    # A repeated conversion verifies its existing certificate and bytes; it never overwrites them.
    if destination.exists():
        safe_path(destination)
        require(destination.is_dir() and (destination/'conversion.json').is_file(),'INCOMPLETE_DECIMAL_DESTINATION')
        record_bytes=(destination/'conversion.json').read_bytes();record=json.loads(record_bytes)
        require(record.get('numericFormat')=='PY_REPR_BINARY64' and record.get('validationSha256')==receipt_file_hash and record.get('publicReleaseAuthorized') is False,'EXISTING_CONVERSION_BINDING_CHANGED')
        expected={group+'/'+source.name:validated_sources[(group,source.name)] for source,group,_,_ in sources}
        entries=record.get('files',[])
        require(len(entries)==len(expected) and {item.get('file') for item in entries}==set(expected),'EXISTING_CONVERSION_FILE_SET_CHANGED')
        actual={p.relative_to(destination).as_posix() for p in destination.rglob('*') if p.is_file()}
        require(actual==set(expected)|{'conversion.json'},'EXISTING_CONVERSION_FILE_SET_CHANGED')
        for item in entries:
            path=safe_path(destination/item['file'])
            require(item.get('sourceSha256')==expected[item['file']] and item.get('decimalSha256')==file_hash(path),'EXISTING_CONVERSION_FILE_CHANGED')
        check_bindings()
        require((destination/'conversion.json').read_bytes()==record_bytes,'CONVERSION_RECEIPT_CHANGED')
        return len(entries)

    # An incomplete conversion is never presented under the completed directory name.
    stage=step/('.decimal_csv_'+uuid.uuid4().hex+'.incomplete');stage.mkdir()
    converted=[]
    for source,group,kind,role in sources:
        target_dir=stage/group;target_dir.mkdir(exist_ok=True);target=target_dir/source.name
        before=file_hash(source)
        require(before==validated_sources[(group,source.name)],'VALIDATED_INPUT_CHANGED')
        if kind=='LOESS':
            convert_loess_file(source,target,{'size':source.stat().st_size,'sha256':before},role)
        else:
            payload=convert_csv(source.read_bytes(),schema_chars(kind,role),manifest=role in {'archive_manifest','aggregate_manifest','loess_manifest'})
            with target.open('xb') as stream:stream.write(payload)
        require(file_hash(source)==before,'SOURCE_CHANGED_DURING_CONVERSION')
        converted.append({'file':target.relative_to(stage).as_posix(),'sourceSha256':before,'decimalSha256':file_hash(target)})
    check_bindings()
    write_once(stage/'conversion.json',{'numericFormat':'PY_REPR_BINARY64','validationSha256':receipt_file_hash,'files':converted,'publicReleaseAuthorized':False})
    require(not destination.exists(),'DECIMAL_DESTINATION_ALREADY_EXISTS')
    stage.rename(destination)
    return len(converted)

def convert_directory(output, model_ids=None):
    from analysis_steps import select_steps
    steps=select_steps(output,model_ids)
    count=0
    for step in steps:
        if not (step/'validation.json').is_file():
            print(step.name+': not converted; independent validation is absent.',flush=True);continue
        n=convert_step(step);count+=1;print(step.name+': '+str(n)+' verified decimal CSV files.',flush=True)
    require(count>0,'NO_VALIDATED_RESULTS_CONVERTED')
