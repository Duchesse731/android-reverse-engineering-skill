export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (!url.pathname.startsWith('/api/')) return new Response(PAGE, {headers:{'content-type':'text/html; charset=utf-8','x-content-type-options':'nosniff','referrer-policy':'no-referrer'}});
    if (!env.ENGINE_URL || !env.ENGINE_TOKEN) return Response.json({connected:false,ready:false,error:'The analysis server is not connected yet.'}, {status:url.pathname==='/api/health'?200:503});
    if (!(/^\/api\/health$/.test(url.pathname) || /^\/api\/jobs(?:\/[a-f0-9]{32}(?:\/download)?)?$/.test(url.pathname))) return new Response('Not found', {status:404});
    if (!['GET','POST'].includes(request.method)) return new Response('Method not allowed', {status:405});
    const headers = new Headers();
    headers.set('Authorization','Bearer '+env.ENGINE_TOKEN);
    if (request.method==='POST') {
      const size=Number(request.headers.get('x-upload-size'));
      if (!Number.isSafeInteger(size) || size<1 || size>64*1024*1024) return Response.json({error:'Choose an APK under 64 MB.'},{status:413});
      headers.set('Content-Length',String(size));
      headers.set('Content-Type','application/octet-stream');
      headers.set('X-File-Name',request.headers.get('x-file-name') || 'app.apk');
    }
    try {
      const response=await fetch(env.ENGINE_URL.replace(/\/$/,'')+url.pathname,{method:request.method,headers,body:request.method==='POST'?request.body:undefined,redirect:'error'});
      const resultHeaders=new Headers({'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});
      for (const key of ['content-type','content-disposition','content-length']) if(response.headers.has(key)) resultHeaders.set(key,response.headers.get(key));
      return new Response(response.body,{status:response.status,headers:resultHeaders});
    } catch {return Response.json({error:'The analysis server is unavailable. Please try again later.'},{status:502});}
  }
};
