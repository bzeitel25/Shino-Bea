import cv2,numpy as np,os,shutil,sys,json
ROOT=os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),'..','..','..'))+'/'; A=ROOT+'ShinoAndBea_Godot/Assets/'; BK=ROOT+'_backup_pre_run175_art/'
def fix(p,cols=(),rows=()):
    if not os.path.exists(BK+p):
        os.makedirs(os.path.dirname(BK+p),exist_ok=True); shutil.copy2(A+p,BK+p)
    im=cv2.imread(BK+p,-1); H,W=im.shape[:2]
    mask=np.zeros((H,W),np.uint8); a=im[:,:,3].astype(np.int32); na=a.copy()
    for c0,c1 in cols:
        mask[:,c0:c1+1]=255
        l=a[:,max(0,c0-2)]; r=a[:,min(W-1,c1+2)]
        for x in range(c0,c1+1): na[:,x]=np.minimum(l,r)
    for r0,r1 in rows:
        r1=min(r1,H-1); mask[r0:r1+1,:]=255
        t=a[max(0,r0-2),:]; b=a[min(H-1,r1+2),:]
        for y in range(r0,r1+1): na[y,:]=np.minimum(na[y,:],np.minimum(t,b)) if cols else np.minimum(t,b)
    # inpaint on a version where transparent px are filled from neighbours so edges don't bleed dark
    rgb=cv2.inpaint(im[:,:,:3],mask,4,cv2.INPAINT_TELEA)
    out=im.copy(); m=mask>0; out[:,:,:3][m]=rgb[m]; out[:,:,3][m]=na[m].astype(np.uint8)
    cv2.imwrite(A+p,out); return int(m.sum())
J=json.loads(sys.argv[1])
for p,spec in J.items(): print(p,fix(p,spec.get('c',[]),spec.get('r',[])))
