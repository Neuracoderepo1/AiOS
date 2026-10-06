import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
const CORS_HEADERS={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
function json(body:unknown,status=200){return new Response(JSON.stringify(body),{status,headers:{"Content-Type":"application/json",...CORS_HEADERS}})}
Deno.serve(async(req:Request)=>{
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers:CORS_HEADERS});if(req.method!=='POST')return json({error:'Method not allowed'},405);
 const authHeader=req.headers.get('Authorization');if(!authHeader)return json({error:'Missing Authorization header'},401);if(Number(req.headers.get('content-length')??0)>32768)return json({error:'Request too large'},413);
 let body:Record<string,unknown>;try{body=await req.json()}catch{return json({error:'Invalid JSON body'},400)}
 const invocation_id=body.invocation_id as string|undefined;const decision=body.decision as string|undefined;const reason=(body.reason as string|undefined)??null;if(!invocation_id||!['approved','rejected'].includes(decision??''))return json({error:'invocation_id and valid decision are required'},422);
 const url=Deno.env.get('SUPABASE_URL')!,anon=Deno.env.get('SUPABASE_ANON_KEY')!,secret=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;const user=createClient(url,anon,{global:{headers:{Authorization:authHeader}}});const {data:userData,error:userErr}=await user.auth.getUser();if(userErr||!userData?.user)return json({error:'Invalid or expired session'},401);const admin=createClient(url,secret);
 const {data:inv,error:invErr}=await admin.from('aios_tool_invocations').select('id,organization_id,status,approval_id').eq('id',invocation_id).maybeSingle();if(invErr)return json({error:'Invocation lookup failed'},500);if(!inv)return json({error:'Invocation not found'},404);if(inv.status!=='requires_approval')return json({error:'Invocation is not awaiting approval'},409);
 const {data:isAdmin,error:roleErr}=await user.rpc('aios_is_org_admin',{org_id:inv.organization_id});if(roleErr)return json({error:'Authorization check failed'},500);if(!isAdmin)return json({error:'Only an organization owner/admin can resolve approvals'},403);
 const {data:result,error:resolveErr}=await admin.rpc('aios_resolve_approval',{p_approval_id:inv.approval_id,p_decision:decision,p_reviewer_id:userData.user.id,p_reason:reason});if(resolveErr){const status=resolveErr.code==='42501'?403:(resolveErr.code==='40001'?409:(resolveErr.code==='22023'||resolveErr.code==='23514'?422:500));return json({error:'Canonical approval resolution failed'},status)}return json(result,200);
});
