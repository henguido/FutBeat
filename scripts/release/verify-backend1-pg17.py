"""Offline native PG17 reconstruction. Connects only to localhost and creates a NEW database.
Never touches an existing database or remote project; keeps its database and evidence.
Vault, pg_net and pg_cron behavior is explicitly outside this native rehearsal.
"""
import argparse,datetime,hashlib,json,subprocess,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--pg-bin');p.add_argument('--docker-container');p.add_argument('--port',type=int,default=56379);p.add_argument('--output',required=True);p.add_argument('--resume',action='store_true');p.add_argument('--refresh-consolidated',action='store_true');args=p.parse_args()
if bool(args.pg_bin)==bool(args.docker_container):raise SystemExit('Choose one local execution mode')
bin=Path(args.pg_bin) if args.pg_bin else None;out=Path(args.output).resolve();out.mkdir(parents=True,exist_ok=True)
if not out.is_relative_to(ROOT/'artifacts'):raise SystemExit('Evidence must stay inside workspace artifacts')
base=[str(bin/'psql.exe') if bin else 'psql','-X','-h','127.0.0.1','-p',str(args.port),'-U','postgres','-v','ON_ERROR_STOP=1','-At']
def call(sql=None,file=None,db='postgres',transaction=False):
 if args.docker_container:
  if not args.docker_container.startswith('fb-consolidation-ext-'):raise SystemExit('Only the disposable consolidation container is allowed')
  cmd=['docker','exec','--user','postgres']+(['-i'] if file else [])+[args.docker_container,'psql','-X','-U','supabase_admin','-v','ON_ERROR_STOP=1','-At','-d',db]+(['--single-transaction'] if transaction else [])+(['-f','-'] if file else ['-c',sql])
  result=subprocess.run(cmd,input=Path(file).read_bytes() if file else None,capture_output=True,timeout=120)
  result.stdout=result.stdout.decode('utf-8');result.stderr=result.stderr.decode('utf-8')
  return result
 cmd=base+['-d',db]+(['--single-transaction'] if transaction else [])+(['-f',str(file)] if file else ['-c',sql])
 return subprocess.run(cmd,capture_output=True,text=True,encoding='utf-8',timeout=120)
version=call('show server_version_num');assert version.returncode==0 and int(version.stdout.strip())//10000==17,'PostgreSQL17 required'
name='postgres' if args.docker_container else 'fb_rebuild_'+uuid.uuid4().hex[:12]
if args.docker_container and not (args.resume or args.refresh_consolidated):
 r=call("select to_regnamespace('futbeat_private') is null");assert r.returncode==0 and r.stdout.strip()=='t','Container must be fresh'
elif not args.docker_container:
 r=call('create database '+name);assert r.returncode==0,r.stderr
expected=json.loads((ROOT/'scripts/release/backend1.expected.json').read_text(encoding='utf-8'))
result={'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'database':name,'serverVersion':version.stdout.strip(),'migrations':[],'checks':{},'limitations':(['Auth is an inert local fixture; no Auth service or provider network was exercised'] if args.docker_container else expected['extensionLimitations'])}
fixture="""do $$ begin if not exists(select 1 from pg_roles where rolname='anon') then create role anon nologin; end if; if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if; if not exists(select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if; end $$;
create schema if not exists auth; create table if not exists auth.users(id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create or replace function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;"""
r=call(fixture,db=name);assert r.returncode==0,r.stderr
previous={}
if args.resume or args.refresh_consolidated:
 assert args.docker_container, 'Resume is restricted to the disposable container'
 saved=json.loads((out/'result.json').read_text(encoding='utf-8'))
 assert saved['database']==name
 assert saved['status']=='FAIL_MIGRATION' if args.resume else len(saved['migrations'])==len(list((ROOT/'supabase/migrations').glob('*.sql')))
 for row in saved['migrations']:
  if row['exit']!=0:break
  if args.refresh_consolidated and row['path']==expected['migration']:continue
  assert hashlib.sha256((ROOT/row['path']).read_bytes()).hexdigest()==row['sha256'], 'Previously passed migration drifted'
  previous[row['path']]=row
for f in sorted((ROOT/'supabase/migrations').glob('*.sql')):
 if f.relative_to(ROOT).as_posix() in previous:
  result['migrations'].append(previous[f.relative_to(ROOT).as_posix()]);continue
 r=call(file=f,db=name,transaction=True);row={'path':f.relative_to(ROOT).as_posix(),'sha256':hashlib.sha256(f.read_bytes()).hexdigest(),'exit':r.returncode};result['migrations'].append(row)
 if r.returncode:
  (out/'failed-migration.log').write_text(r.stderr,encoding='utf-8');result['status']='FAIL_MIGRATION';break
 if len(result['migrations'])%30==0:print('Applied',len(result['migrations']),flush=True)
else:
 checks=result['checks'];checks['functions']=[]
 for sig,want in expected['functions'].items():
  r=call("select md5(pg_get_functiondef('"+sig+"'::regprocedure))",db=name);got=r.stdout.strip();checks['functions'].append({'signature':sig,'expected':want,'actual':got,'pass':r.returncode==0 and got==want})
 checks['signaturePrefixFunctions']=[]
 for sig,want in expected.get('signaturePrefixes',{}).items():
  r=call("select md5(pg_get_functiondef('"+sig+"'::regprocedure))",db=name);got=r.stdout.strip();checks['signaturePrefixFunctions'].append({'signature':sig,'expectedPrefix':want,'actual':got,'pass':r.returncode==0 and got.startswith(want)})
 checks['confirmedPrefixFunctions']=[]
 for fn,want in expected.get('functionPrefixes',{}).items():
  schema,proname=fn.split('.')
  q="select md5(pg_get_functiondef(p.oid)) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='"+schema+"' and p.proname='"+proname+"'"
  r=call(q,db=name);got=r.stdout.strip();checks['confirmedPrefixFunctions'].append({'function':fn,'expectedPrefix':want,'actual':got,'pass':r.returncode==0 and got.startswith(want) and '\n' not in got})
 r=call("select md5(rtrim(pg_get_functiondef('futbeat_private.build_compact_calendar(date,date,text)'::regprocedure),E'\\n'))",db=name);checks['calendar']={'actual':r.stdout.strip(),'pass':r.returncode==0 and r.stdout.strip()==expected['calendarRtrimMd5']}
 checks['missingPrerequisites']=[]
 for sig in expected['requiredPrerequisites']:
  r=call("select to_regprocedure('"+sig+"') is not null",db=name)
  if r.returncode or r.stdout.strip()!='t':checks['missingPrerequisites'].append(sig)
 for rel in expected['requiredRelations']:
  r=call("select to_regclass('"+rel+"') is not null",db=name)
  if r.returncode or r.stdout.strip()!='t':checks['missingPrerequisites'].append(rel)
 invariants={
 'pushClosed':"select (select mode='dry_run' from futbeat_private.push_settings where id) and not exists(select 1 from futbeat_private.push_pilot_devices)",
 'noHistoricalReplay':"select not exists(select 1 from futbeat_private.player_identity_merges) and not exists(select 1 from billing_private.purchases)",
 'billingPrivateAcl':"select not has_schema_privilege('anon','billing_private','USAGE') and not has_schema_privilege('authenticated','billing_private','USAGE')",
 'pilotGateClosed':"select not futbeat_private.push_deliverable('11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222','fcm','live')",
 'unsupportedPersonalEvent':"select not futbeat_private.notify_allowed_p('{}'::jsonb,'player','kickoff') and not futbeat_private.notify_allowed_p('{}'::jsonb,'player','own_goal')",
 'preferencesDisableEvent':"select not futbeat_private.notify_allowed_p('{\"notification_scopes\":{\"player\":{\"goal\":false}}}'::jsonb,'player','goal')",
 'billingDeletionTrigger':"select exists(select 1 from pg_trigger where tgname='futbeat_billing_forget_deleted_user')",
 'passivePolicyDisabled':"select exists(select 1 from futbeat_private.passive_api_policy where singleton and not enabled and cardinality(client_keys)=0)",
 'leaseRpcAcl':"select has_function_privilege('service_role','public.futbeat_try_worker_lease(text,integer,text)','EXECUTE') and not has_function_privilege('anon','public.futbeat_try_worker_lease(text,integer,text)','EXECUTE') and not has_function_privilege('authenticated','public.futbeat_try_worker_lease(text,integer,text)','EXECUTE')",
 'qaReadersAclAndVolatility':"select count(*)=4 and bool_and(p.provolatile='s' and has_function_privilege('service_role',p.oid,'EXECUTE') and not has_function_privilege('anon',p.oid,'EXECUTE') and not has_function_privilege('authenticated',p.oid,'EXECUTE')) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('futbeat_read_qa_stored_calendar','futbeat_read_qa_stored_explore','futbeat_read_qa_stored_national_teams','futbeat_read_qa_stored_search')",
 'timezonePrivateAcl':"select bool_and(not has_function_privilege('anon',p.oid,'EXECUTE') and not has_function_privilege('authenticated',p.oid,'EXECUTE') and not has_function_privilege('service_role',p.oid,'EXECUTE')) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='futbeat_private' and p.proname in ('is_timezone_name','match_detail_bucket_at')",
 'o1PrivateTable':"select relrowsecurity and not has_table_privilege('anon',oid,'SELECT') and not has_table_privilege('authenticated',oid,'SELECT') and not has_table_privilege('service_role',oid,'SELECT') from pg_class where oid='futbeat_private.detail_planner_schedule'::regclass",
 'indexesValid':"select count(*)=2 and bool_and(i.indisvalid) from pg_index i join pg_class c on c.oid=i.indexrelid where c.relname in ('entities_player_lineup_external_idx','lineup_player_alerts_player_idx')"}
 checks['invariants']={}
 for key,q in invariants.items():
  r=call(q,db=name);checks['invariants'][key]={'pass':r.returncode==0 and r.stdout.strip()=='t','exit':r.returncode}
 r=call("select public.futbeat_request_match_detail('fb_match_reconstruction_missing')",db=name);checks['d1Runtime']={'pass':r.returncode==0,'exit':r.returncode,'error':r.stderr.strip() if r.returncode else None}
 # Repeat only new declarative changes, in order, including final overrides.
 repeat=[]
 for path in [expected['migration'],*expected.get('finalOverrides',[])]:
  r=call(file=ROOT/path,db=name,transaction=True);repeat.append({'path':path,'pass':r.returncode==0,'exit':r.returncode})
  if r.returncode:(out/'repeat.log').write_text(r.stderr,encoding='utf-8');break
 checks['idempotence']={'pass':all(x['pass'] for x in repeat),'steps':repeat}
 for row in checks['signaturePrefixFunctions']:
  r=call("select md5(pg_get_functiondef('"+row['signature']+"'::regprocedure))",db=name);row['afterRepeat']=r.stdout.strip();row['pass']=row['pass'] and r.returncode==0 and row['afterRepeat']==row['actual']
 r=call(file=ROOT/'backend/test/fixtures/backend1_d1_offline.sql',db=name);checks['d1P0NoDirectWake']={'pass':r.returncode==0,'exit':r.returncode}
 if r.returncode:(out/'d1-fixture.log').write_text(r.stderr,encoding='utf-8')
 checks['functionHashesPass']=all(x['pass'] for x in checks['functions']) and all(x['pass'] for x in checks['confirmedPrefixFunctions']) and all(x['pass'] for x in checks['signaturePrefixFunctions']) and checks['calendar']['pass']
 result['status']='PASS' if checks['functionHashesPass'] and not checks['missingPrerequisites'] and checks['d1Runtime']['pass'] and checks['d1P0NoDirectWake']['pass'] and checks['idempotence']['pass'] and all(x['pass'] for x in checks['invariants'].values()) else 'FAIL_DEPENDENCIES_OR_CONTRACT'
(out/'result.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
print(json.dumps({'status':result['status'],'database':name,'migrations':len(result['migrations']),'checks':result['checks']},indent=2))
raise SystemExit(0 if result['status']=='PASS' else 1)
