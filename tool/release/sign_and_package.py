"""Sign an official arm64 APK, verify its identity, and make Release-sized parts.

Private keystores stay outside this repository. Passwords arrive via environment.
"""
from pathlib import Path
import argparse,hashlib,json,os,subprocess

def digest(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for chunk in iter(lambda:f.read(8*1024*1024),b''):h.update(chunk)
    return h.hexdigest()

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--apk',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--apksigner-jar',type=Path,required=True)
    args=p.parse_args();root=Path(__file__).resolve().parents[2]
    for key in ['MIYIN_STORE_PASSWORD','MIYIN_KEYSTORE_PATH','MIYIN_LEGACY_KEYSTORE_PATH']:
        if not os.environ.get(key):raise RuntimeError('Missing signing configuration: '+key)
    if args.output.resolve().is_relative_to(root/'app/miyin/assets'):raise ValueError('Never put signed builds in bundled source assets')
    args.output.mkdir(parents=True,exist_ok=True)
    import re
    version=re.search(r'^version:\s*(\S+)',(root/'app/miyin/pubspec.yaml').read_text(),re.M)[1]
    name='Miyin-'+version+'-arm64.apk';signed=args.output/name
    java=[str(Path(os.environ['JAVA_HOME'])/'bin'/('java.exe' if os.name=='nt' else 'java')),'-jar',str(args.apksigner_jar)]
    env=os.environ.copy();env['MIYIN_LEGACY_PASSWORD']='android'
    command=java+['sign','--ks',env['MIYIN_LEGACY_KEYSTORE_PATH'],'--ks-pass','env:MIYIN_LEGACY_PASSWORD','--next-signer','--ks',env['MIYIN_KEYSTORE_PATH'],'--ks-pass','env:MIYIN_STORE_PASSWORD','--ks-key-alias','miyin-release','--lineage',str(root/'docs/release/signing/debug-to-release.lineage'),'--rotation-min-sdk-version','28','--out',str(signed),str(args.apk)]
    subprocess.run(command,env=env,check=True)
    verified=subprocess.check_output(java+['verify','--verbose','--print-certs',str(signed)],text=True)
    expected=json.loads((root/'docs/release/signing/certificate.json').read_text())['certificateSha256']
    if 'certificate SHA-256 digest: '+expected not in verified:raise RuntimeError('Unexpected release certificate')
    (args.output/'SIGNATURE.txt').write_text(verified,encoding='utf-8')
    parts=[]
    with signed.open('rb') as f:
        n=0
        while True:
            data=f.read(8*1024*1024)
            if not data:break
            n+=1;part=args.output/(name+'.part'+str(n));remaining=1536*1024*1024
            with part.open('wb') as out:
                while data:
                    out.write(data);remaining-=len(data)
                    if not remaining:break
                    data=f.read(min(8*1024*1024,remaining))
            parts.append({'file':part.name,'bytes':part.stat().st_size,'sha256':digest(part)})
    checksum=digest(signed)
    manifest={'version':version,'apk':name,'bytes':signed.stat().st_size,'sha256':checksum,'certificateSha256':expected,'rotationMinSdk':28,'parts':parts}
    (args.output/'DOWNLOAD-MANIFEST.json').write_text(json.dumps(manifest,indent=2)+'\n')
    (args.output/'SHA256SUMS.txt').write_text('\n'.join(a['sha256']+'  '+a['file'] for a in parts)+'\n'+checksum+'  '+name+'\n')
    bat=f'''@echo off
cd /d "%~dp0"
copy /b "{name}.part1"+"{name}.part2" "{name}"
if errorlevel 1 exit /b 1
powershell -NoProfile -Command "if((Get-FileHash -LiteralPath './{name}').Hash -ne '{checksum}'){{throw 'Checksum mismatch'}}; Write-Host 'APK verified'"
pause
'''
    (args.output/'Merge-APK-Windows.cmd').write_bytes(bat.replace('\n','\r\n').encode('ascii'))
    (args.output/'INSTALL-README.txt').write_text('Download all numbered parts and join them in order before installation. Windows: run Merge-APK-Windows.cmd in the same folder. Verify SHA256SUMS.txt. Android9+ uses the new release key with legacy update lineage; Android7/8 retains the legacy signer. No signing key is included.\n',encoding='utf-8')
    print(json.dumps(manifest,indent=2))

if __name__=='__main__':main()
