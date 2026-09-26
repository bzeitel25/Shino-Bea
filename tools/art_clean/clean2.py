import cv2,numpy as np
K8=np.ones((3,3),np.uint8)
def _rings(a):
    m=(a>0).astype(np.uint8)
    ring=(m>0)&(cv2.erode(m,K8,borderType=cv2.BORDER_CONSTANT,borderValue=0)==0)
    return m>0,ring
def _inward_lum(lum,interior):
    f=interior.astype(np.float32)
    s=cv2.filter2D(lum*f,-1,np.ones((3,3),np.float32),borderType=cv2.BORDER_CONSTANT)
    n=cv2.filter2D(f,-1,np.ones((3,3),np.float32),borderType=cv2.BORDER_CONSTANT)
    return s/np.maximum(n,1e-6),n
def _cand(im):
    hsv=cv2.cvtColor(im[:,:,:3],cv2.COLOR_BGR2HSV); H=hsv[:,:,0].astype(int);S=hsv[:,:,1];V=hsv[:,:,2]
    lum=cv2.cvtColor(im[:,:,:3],cv2.COLOR_BGR2GRAY).astype(np.float32)
    b=im[:,:,:3].astype(np.float32); C=b.max(-1)-b.min(-1)
    m,ring=_rings(im[:,:,3]); il,n=_inward_lum(lum,m&~ring); iC,_=_inward_lum(C,m&~ring)
    c=ring&(n>0)&(S>110)&(C>32)&((lum>il+28)|(C>iC+28))
    return c,H,ring
def hue_dist(H,h): d=np.abs(H-h); return np.minimum(d,180-d)
def pick_hue(im,minfrac=0.12):
    c,H,ring=_cand(im)
    if c.sum()<30: return None,0,int(ring.sum())
    hist=np.bincount(H[c],minlength=180).astype(float)
    sm=np.array([hist[[(i+k)%180 for k in range(-6,7)]].sum() for i in range(180)])
    h=int(sm.argmax()); cnt=int((c&(hue_dist(H,h)<=12)).sum())
    if cnt<minfrac*ring.sum(): return None,cnt,int(ring.sum())
    return h,cnt,int(ring.sum())
def defringe(im,h,passes=3):
    im=im.copy(); tot=0
    for _ in range(passes):
        c,H,ring=_cand(im); kill=c&(hue_dist(H,h)<=12)
        if not kill.any(): break
        im[:,:,3][kill]=0; tot+=int(kill.sum())
    # orphan specks of key hue left floating
    hsv=cv2.cvtColor(im[:,:,:3],cv2.COLOR_BGR2HSV); H=hsv[:,:,0].astype(int); S=hsv[:,:,1]
    keyish=(hue_dist(H,h)<=14)&(S>90)
    nl,lab,st,_=cv2.connectedComponentsWithStats((im[:,:,3]>0).astype(np.uint8),8)
    small=np.isin(lab,[j for j in range(1,nl) if st[j,4]<=8])
    kill=small&keyish
    im[:,:,3][kill]=0; tot+=int(kill.sum())
    return im,tot
def shadow_fix(im,h,frac=0.30):
    a=im[:,:,3]; ys,xs=np.nonzero(a)
    if len(ys)==0: return im,0
    hsv=cv2.cvtColor(im[:,:,:3],cv2.COLOR_BGR2HSV); H=hsv[:,:,0].astype(int);S=hsv[:,:,1];V=hsv[:,:,2].astype(float)
    y0=int(ys.max()-(ys.max()-ys.min())*frac)
    cand=(a>0)&(hue_dist(H,h)<=14)&(S>110)&(V<175)
    cand[:y0]=False
    cand=cv2.morphologyEx(cand.astype(np.uint8),cv2.MORPH_CLOSE,K8)>0
    nl,lab,st,_=cv2.connectedComponentsWithStats(cand.astype(np.uint8),8)
    sel=np.zeros_like(cand)
    for j in range(1,nl):
        x,y,w,hh,ar=st[j]
        if y+hh>=ys.max()-3 and ar>=60 and w>=hh*0.9: sel|=lab==j
    if not sel.any(): return im,0
    # shadow body = selected pixels; alpha from value relative to key brightness
    Vk=255.0; al=np.clip(1-V[sel]/Vk,0.25,0.8); alpha=float(np.median(al))*255*0.85
    im=im.copy()
    # fill holes inside the ellipse region that are shadow-coloured noise; keep feet (non-sel) untouched
    im[:,:,:3][sel]=(12,10,14)
    im[:,:,3][sel]=int(alpha)
    # soften the rim of the shadow
    rim=sel&(cv2.erode(sel.astype(np.uint8),K8)==0)
    im[:,:,3][rim]=int(alpha*0.55)
    return im,int(sel.sum())
