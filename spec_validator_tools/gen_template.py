# Regenerates the TEMPLATE constant for spec_validator from the check-sheet workbook
# (sheet '전체데이터': NO | 품번 | 차종 | 검사부위 | 중심규격 | 상한공차 | 하한공차).
# usage: python3 gen_template.py <ConVAS_검사기준서.xlsx> [out.js]
#        then paste out.js over the `const TEMPLATE = [...]` block in the html.
import openpyxl, re, json, sys
wb=openpyxl.load_workbook(sys.argv[1],data_only=True)
ws=wb['전체데이터']
groups={}
order=[]
for r in ws.iter_rows(min_row=2,values_only=True):
    no,part,name,pos,nom,up,lo=r[:7]
    if no is None: continue
    if no not in groups: groups[no]={'p':part,'name':str(name).strip(),'r':[]}; order.append(no)
    groups[no]['r'].append([str(pos).strip(),float(nom),float(up),float(lo)])
def key_side(name):
    n=name.upper()
    side='LHD' if 'LHD' in n else ('RHD' if 'RHD' in n else '')
    n=re.sub(r'\b[LR]HD\b','',n); n=re.sub(r'ASPHERIC|MIRROR','',n)
    return re.sub(r'[^A-Z0-9]','',n), side
seen=set(); out=[]
for no in order:
    g=groups[no]; k,s=key_side(g['name'])
    sig=(g['p'],k,s,json.dumps(g['r']))
    if sig in seen: continue
    seen.add(sig)
    out.append({'p':g['p'],'n':g['name'],'k':k,'s':s,'r':g['r'],'no':no})
lines=[]
for e in out:
    rs=','.join('["%s",%s,%s,%s]'%(a,repr(b),repr(c),repr(d)) for a,b,c,d in e['r'])
    lines.append('  {p:"%s",n:"%s",k:"%s",s:"%s",no:%d,r:[%s]}'%(e['p'],e['n'],e['k'],e['s'],e['no'],rs))
open(sys.argv[2] if len(sys.argv)>2 else 'template.js','w').write('const TEMPLATE = [\n'+',\n'.join(lines)+'\n];\n')
print(len(out),'entries from',len(order),'sheet blocks')
for e in out: print(e['no'],e['p'],e['k'],e['s'] or '-',len(e['r']))
