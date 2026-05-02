const fs = require('fs');
const path = require('path');

const filePath = path.join(__dirname, 'entry/src/main/ets/pages/Index.ets');
let content = fs.readFileSync(filePath, 'utf8');

// 替换 $r('app.color.xxx') 为 $r("app.color.xxx")
// 匹配模式: $r('app.color.任意内容')
content = content.replace(/\$r\('app\.color\.([^']+)'/g, '$r("app.color.$1"');

fs.writeFileSync(filePath, content, 'utf8');
console.log('Fixed $r() quote nesting issues');
