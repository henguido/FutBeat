"""Probe actual extensions only in the disposable, network-none FutBeat validation container.
Docs: https://supabase.com/docs/guides/cron/quickstart
      https://supabase.com/docs/guides/database/extensions/pg_net
      https://supabase.com/docs/guides/database/vault
No migrations, production credentials, provider calls, or sporting events.
"""
import argparse,subprocess,json,time,datetime,uuid
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--container',required=True);p.add_argument('--output',required=True);a=p.parse_args()
root=Path(__file__).resolve().parents[2];out=Path(a.output).resolve();assert out.is_relative_to(root/'artifacts');out.mkdir(parents=True,exist_ok=True)
assert a.container.startswith('fb-consolidation-ext-')
meta=subprocess.run(['docker','inspect',a.container],capture_output=True,timeout=15,check=True)
info=json.loads(meta.stdout)[0];assert info['HostConfig']['NetworkMode']=='none' and not info['HostConfig'].get('PortBindings')
result={'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'imageId':info['Image'],'network':'none','checks':{},'usesProductionSecrets':False}
def sql(q):
 r=subprocess.run(['docker','exec','--user','postgres',a.container,'psql','-X','-U','supabase_admin','-d','postgres','-v','ON_ERROR_STOP=1','-At','-c',q],capture_output=True,timeout=20)
 if r.returncode:raise RuntimeError(r.stderr.decode('utf-8'))
 return r.stdout.decode('utf-8').strip()
def check(name,ok):
 result['checks'][name]=bool(ok)
 if not ok:raise RuntimeError(name+' failed')
def scheduler(enabled):
 sql('alter system set cron.launch_active_jobs='+('on' if enabled else 'off'));sql('select pg_reload_conf()')
job=None
try:
 result['postgres']=sql('show server_version');check('postgres17',result['postgres'].startswith('17.'))
 result['extensions']=json.loads(sql("select json_object_agg(extname,extversion) from pg_extension where extname in ('pg_net','pg_cron','supabase_vault')"))
 check('realExtensionsInstalled',all(x in result['extensions'] for x in ['pg_net','pg_cron','supabase_vault']))
 # The application jobs remain inert throughout. Only our SQL-only probe is activated.
 scheduler(False);sql('update cron.job set active=false')
 sql('create schema futbeat_extension_probe; create table futbeat_extension_probe.ticks(id int primary key,at timestamptz default now()); create table futbeat_extension_probe.requests(id bigint primary key);')
 # The generated fixture plaintext never leaves this DO block; its row is rolled back.
 sql("""begin; do $test$ declare v_plain text:='local-extension-fixture-'||gen_random_uuid(); v_id uuid; begin
  v_id:=vault.create_secret(v_plain,'futbeat-local-vault-probe');
  if not exists(select 1 from vault.decrypted_secrets where id=v_id and decrypted_secret=v_plain) then raise exception 'Vault round trip failed'; end if;
  if exists(select 1 from vault.secrets where id=v_id and secret=v_plain) then raise exception 'Vault stored plaintext'; end if;
 end $test$; rollback;""")
 check('vaultEncryptionRoundTripRollback',sql("select not exists(select 1 from vault.secrets where name='futbeat-local-vault-probe')")=='t')
 check('vaultAnonymousDenied',sql("select not has_table_privilege('anon','vault.decrypted_secrets','SELECT') and not has_table_privilege('authenticated','vault.decrypted_secrets','SELECT')")=='t')
 sql("""begin; insert into futbeat_extension_probe.requests select net.http_post(url:='http://127.0.0.1:1/futbeat-extension-probe',body:='{"probe":true}'::jsonb,headers:='{"Content-Type":"application/json"}'::jsonb,timeout_milliseconds:=1000);
 do $test$ begin
 if not exists(select 1 from net.http_request_queue q join futbeat_extension_probe.requests p on p.id=q.id) then raise exception 'HTTP queue not transactional'; end if;
 if exists(select 1 from net._http_response r join futbeat_extension_probe.requests p on p.id=r.id) then raise exception 'HTTP dispatched before commit'; end if;
 end $test$; commit;""")
 for _ in range(30):
  state=sql("select exists(select 1 from net._http_response r join futbeat_extension_probe.requests p on p.id=r.id where r.error_msg is not null or r.status_code is not null)")
  if state=='t':break
  time.sleep(0.5)
 check('pgNetTransactionalQueueAndAsyncWorker',state=='t')
 check('pgNetLocalFailureClassified',sql("select exists(select 1 from net._http_response r join futbeat_extension_probe.requests p on p.id=r.id where r.error_msg is not null)")=='t')
 job=int(sql("select cron.schedule('futbeat-extension-probe','1 second','insert into futbeat_extension_probe.ticks(id) values(1) on conflict do nothing')"))
 time.sleep(2)
 check('cronDisabledBeforeProbe',sql('select count(*) from futbeat_extension_probe.ticks')=='0')
 scheduler(True)
 for _ in range(30):
  state=sql('select count(*) from futbeat_extension_probe.ticks')
  if state=='1':break
  time.sleep(0.5)
 check('cronActualScheduledExecution',state=='1')
 check('cronUnschedule',sql('select cron.unschedule('+str(job)+')')=='t');job=None
 check('noApplicationJobsActivated',sql('select not exists(select 1 from cron.job where active)')=='t')
 result['status']='PASS'
except Exception as exc:
 result['status']='FAIL';result['error']=str(exc)
finally:
 try:
  if job is not None:sql('select cron.unschedule('+str(job)+')')
  scheduler(False)
 except Exception as exc:result['cleanupError']=str(exc);result['status']='FAIL'
(out/'result.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
print(json.dumps(result,indent=2));raise SystemExit(0 if result['status']=='PASS' else 1)
