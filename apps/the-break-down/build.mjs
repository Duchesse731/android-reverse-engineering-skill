import fs from 'node:fs';
const html=fs.readFileSync('web/index.html','utf8').replace('/* APP_CSS */',fs.readFileSync('web/app.css','utf8')).replace('/* APP_JS */',fs.readFileSync('web/app.js','utf8'));
fs.mkdirSync('dist/server',{recursive:true});
fs.writeFileSync('dist/server/index.js','const PAGE='+JSON.stringify(html)+';\n'+fs.readFileSync('src-worker.mjs','utf8'));
