import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS_HEADERS={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
function json(body:unknown,status=200){return new Response(JSON.stringify(body),{status,headers:{"Content-Type":"application/json",...CORS_HEADERS}})}
async function hash(v:unknown){const d=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(JSON.stringify(v)));return Array.from(new Uint8Array(d)).map(x=>x.toString(16).padStart(2,'0')).join('')}
async function claude(key:string,prompt:string){const start=Date.now();const r=await fetch('https://api.anthropic.com/v1/messages',{method:'POST',headers:{'x-api-key':key,'anthropic-version':'2023-06-01','content-type':'application/json'},body:JSON.stringify({model:'claude-sonnet-4-6',max_tokens:900,messages:[{role:'user',content:prompt}]})});const ms=Date.now()-start;const data=await r.json().catch(()=>({}));if(!r.ok)throw new Error(`Anthropic API error: ${r.status}`);const text=data.content?.find((b:{type:string})=>b.type==='text')?.text;if(!text)throw new Error('No model output');return{text,input_tokens:data.usage?.input_tokens??0,output_tokens:data.usage?.output_tokens??0,latency_ms:ms}}
function parse(text:string){const s=text.replace(/```json|```/g,'').trim();const a=s.indexOf('['),b=s.lastIndexOf(']');if(a<0||b<=a)throw new Error('Model did not return a JSON task array');return JSON.parse(s.slice(a,b+1))}
Deno.serve(async(req:Request)=>{
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers:CORS_HEADERS}); if(req.method!=='POST')return json({error:'Method not allowed'},405);
 const auth=req.headers.get('Authorization');if(!auth)return json({error:'Missing Authorization header'},401);let body:Record<string,unknown>;try{if(Number(req.headers.get('content-length')??0)>65536)return json({error:'Request too large'},413);body=await req.json()}catch{return json({error:'Invalid JSON body'},400)}
 const organization_id=body.organization_id as string|undefined,title=body.title as string|undefined,objective=body.objective as string|undefined;if(!organization_id||!title||!objective)return json({error:'organization_id, title, and objective are required'},400);
 const url=Deno.env.get('SUPABASE_URL')!,anon=Deno.env.get('SUPABASE_ANON_KEY')!,secret=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,key=Deno.env.get('ANTHROPIC_API_KEY');if(!key)return json({error:'AI dependency unavailable'},503);
 const user=createClient(url,anon,{global:{headers:{Authorization:auth}}});const {data:u,error:ue}=await user.auth.getUser();if(ue||!u?.user)return json({error:'Invalid or expired session'},401);const {data:member}=await user.rpc('aios_is_org_member',{org_id:organization_id});if(!member)return json({error:'Not authorized for this organization'},403);
 const admin=createClient(url,secret);
 const {data:agents,error:ae}=await admin.from('aios_agents').select('id,role,status,authority').eq('organization_id',organization_id).neq('status','suspended');if(ae)return json({error:'Agent lookup failed'},500);
 const eligible=(agents??[]).filter(a=>a.role==='Research Director' && Array.isArray(a.authority?.allowed_tools));
 const candidates=[] as typeof eligible;
 for(const agent of eligible){const {data:c}=await admin.from('aios_contracts').select('id,version,is_active,allowed_tools').eq('agent_id',agent.id).eq('organization_id',organization_id).eq('is_active',true);if((c??[]).length===1)candidates.push(agent)}
 const selected=candidates[0];if(!selected)return json({error:'No eligible research agent with exactly one active contract'},422);
 const {data:mission,error:me}=await admin.from('aios_missions').insert({organization_id,title,objective,status:'queued'}).select('*').single();if(me)return json({error:'Mission creation failed'},500);
 let tasks:any[]=[];
 if(/support|customer|ticket|recurring problem/i.test(objective)){
   const {data:t,error:te}=await admin.from('aios_tasks').insert({organization_id,mission_id:mission.id,assigned_agent_id:selected.id,title:'Identify the five largest recurring customer-support problems',instructions:objective,risk_level:'low',status:'queued'}).select('*').single();if(te)return json({error:'Task creation failed'},500);tasks=[t];
 }else{
   const prompt=`Decompose this mission into 1-3 concrete tasks for the assigned research agent. Return ONLY JSON array with title,instructions,risk_level. Do not invent tools or permissions. Mission title: ${title}. Objective: ${objective}`;
   const run=await claude(key,prompt);let drafts:any[];try{drafts=parse(run.text)}catch{return json({error:'Model produced invalid mission plan'},422)}
   if(!Array.isArray(drafts)||drafts.length<1||drafts.length>3)return json({error:'Model returned an invalid task count'},422);
   for(const d of drafts){if(typeof d?.title!=='string'||typeof d?.instructions!=='string')return json({error:'Model returned invalid task fields'},422);const risk=['low','medium','high'].includes(d.risk_level)?d.risk_level:'low';const {data:t,error:te}=await admin.from('aios_tasks').insert({organization_id,mission_id:mission.id,assigned_agent_id:selected.id,title:d.title,instructions:d.instructions,risk_level:risk,status:'queued'}).select('*').single();if(te)return json({error:'Task creation failed'},500);tasks.push(t)}
   await admin.from('aios_model_runs').insert({organization_id,agent_id:selected.id,task_id:tasks[0]?.id??null,provider:'anthropic',model:'claude-sonnet-4-6',input_hash:await hash(prompt),output_hash:await hash(run.text),prompt_reference:'kernel.mission_decomposition.v1',input_tokens:run.input_tokens,output_tokens:run.output_tokens,latency_ms:run.latency_ms,status:'succeeded',outcome:'mission_decomposition'});
 }
 await admin.from('aios_audit_events').insert({organization_id,actor_user_id:u.user.id,actor_type:'user',mission_id:mission.id,event_type:'mission_created',risk_level:'low',action:'launch_mission',decision:'allow',new_state:'queued',metadata:{mission_id:mission.id,task_count:tasks.length,agent_id:selected.id}});
 return json({mission_id:mission.id,status:'queued',agent_id:selected.id,tasks},201);
});
