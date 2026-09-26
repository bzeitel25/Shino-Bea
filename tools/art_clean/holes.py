import cv2,numpy as np
def key_from_transparent(im):
    a=im[:,:,3]; tr=im[:,:,:3][a==0].astype(np.float32)
    if len(tr)<100: return None
    # use transparent pixels adjacent to the sprite (most representative of bg)
    m=(a>0).astype(np.uint8); nb=(cv2.dilate(m,np.ones((5,5),np.uint8))>0)&(a==0)
    c=im[:,:,:3][nb].astype(np.float32)
    if len(c)<50: return None
    med=np.median(c,0)
    sat=med.max()-med.min()
    return med if sat>90 else None
def holes(im,K,tol=38,minarea=25):
    a=im[:,:,3]; b=im[:,:,:3].astype(np.float32)
    d=np.sqrt(((b-K)**2).sum(-1))
    cand=((a>0)&(d<tol)).astype(np.uint8)
    nl,lab,st,_=cv2.connectedComponentsWithStats(cand,4)
    sel=np.zeros(a.shape,bool)
    for j in range(1,nl):
        if st[j,4]>=minarea: sel|=lab==j
    # grow by 1px into fringe pixels that are closer to K than tol*1.8
    ring=(cv2.dilate(sel.astype(np.uint8),np.ones((3,3),np.uint8))>0)&~sel&(a>0)&(d<tol*1.8)
    sel|=ring
    return sel
