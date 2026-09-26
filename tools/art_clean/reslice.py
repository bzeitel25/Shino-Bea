import cv2,numpy as np,os,sys,re,json
sys.path.insert(0,os.path.dirname(os.path.abspath(__file__))); from clean2 import pick_hue,defringe,hue_dist
ROOT=os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),'..','..','..'))+'/'; A=ROOT+'ShinoAndBea_Godot/Assets/'; BK=ROOT+'_backup_pre_run175_art/'
rig=open(ROOT+'ShinoAndBea_Godot/scripts/MonsterRig.gd').read()
FR={m[0].split('/')[-1]:int(m[1]) for m in re.findall(r'"path":\s*"(res://[^"]+)",\s*"frames":\s*(\d+)',rig)}
_mc={}
def key_master(path,tol=100,tol_in=45,dil=22):
    if path in _mc: return _mc[path]
    m=cv2.imread(path,cv2.IMREAD_UNCHANGED)[:,:,:3]
    H,W=m.shape[:2]
    border=np.concatenate([m[:6].reshape(-1,3),m[-6:].reshape(-1,3),m[:,:6].reshape(-1,3),m[:,-6:].reshape(-1,3)])
    q=(border//8).astype(int); keys,cnt=np.unique(q[:,0]*10000+q[:,1]*100+q[:,2],return_counts=True)
    k=keys[cnt.argmax()]; K=np.array([k//10000,(k//100)%100,k%100])*8+4
    f=m.astype(np.float32)
    g=f.mean(-1,keepdims=True); ch=f-g
    kc=K-K.mean(); kn=np.linalg.norm(kc); kh_=kc/kn
    dom=(ch*kh_).sum(-1)                      # chroma along the key direction
    perp=np.linalg.norm(ch-dom[...,None]*kh_,axis=-1)
    d=np.sqrt(((f-K)**2).sum(-1))
    bgc=(d<tol).astype(np.uint8)
    nl,lab,st,_=cv2.connectedComponentsWithStats(bgc,4)
    bg=np.zeros((H,W),bool)
    for j in range(1,nl):
        x,y,w,h,ar=st[j]
        if x==0 or y==0 or x+w==W or y+h==H or ar>20000: bg|=lab==j
    # strongly key-dominant pixels anywhere (enclosed pockets, specks)
    bg|=(dom>0.62*kn)&(perp<0.35*kn)
    # Gemini watermark sparkle: whitened key-hue pixels in the bottom-right corner
    hsv=cv2.cvtColor(m,cv2.COLOR_BGR2HSV); kh=int(cv2.cvtColor(np.uint8([[K]]),cv2.COLOR_BGR2HSV)[0,0,0])
    hd=np.abs(hsv[:,:,0].astype(int)-kh); hd=np.minimum(hd,180-hd)
    wm=(hd<=18)&(hsv[:,:,1]<215)&(hsv[:,:,2]>150)
    wm[:int(H*0.72)]=False; wm[:,:int(W*0.82)]=False
    bg|=cv2.dilate(wm.astype(np.uint8),np.ones((3,3),np.uint8))>0
    # remove 1-2px islands
    fg=(~bg).astype(np.uint8)
    nl,lab,st,_=cv2.connectedComponentsWithStats(fg,8)
    tiny=np.isin(lab,[j for j in range(1,nl) if st[j,4]<=6]); fg[tiny]=0
    # despill within 3px of the silhouette: strip chroma along the key direction
    edge=(fg>0)&(cv2.erode(fg,np.ones((7,7),np.uint8))==0)
    sp=np.clip(dom,0,None)*edge
    f2=f-sp[...,None]*kh_
    out=np.dstack([np.clip(f2,0,255).astype(np.uint8),fg*255])
    kill=edge&(dom>0.35*kn)&(perp<0.45*kn)     # mostly-key edge pixels -> gone
    out[:,:,3][kill]=0
    _mc[path]=(out,m,K)
    return _mc[path]
def locate(master_bgr,tpl,mask):
    s=4
    mb=cv2.resize(master_bgr,None,fx=1/s,fy=1/s,interpolation=cv2.INTER_AREA)
    tb=cv2.resize(tpl,None,fx=1/s,fy=1/s,interpolation=cv2.INTER_AREA)
    mk=(cv2.resize(mask.astype(np.uint8)*255,(tb.shape[1],tb.shape[0]),interpolation=cv2.INTER_AREA)>250).astype(np.uint8)
    r=cv2.matchTemplate(mb,tb,cv2.TM_SQDIFF,mask=mk*255)
    _,_,mn,_=cv2.minMaxLoc(r); x0,y0=mn[0]*s,mn[1]*s
    best=None
    H,W=master_bgr.shape[:2]; th,tw=tpl.shape[:2]
    for dy in range(-6,7):
        for dx in range(-6,7):
            x,y=x0+dx,y0+dy
            if x<0 or y<0 or x+tw>W or y+th>H: continue
            diff=np.abs(master_bgr[y:y+th,x:x+tw].astype(int)-tpl.astype(int)).sum(-1)[mask]
            sc=diff.mean()
            if best is None or sc<best[0]: best=(sc,x,y)
    return best
def reslice(strip, master, drop_small_frac=0.0, sym=True, src_dir=None):
    src=(BK if os.path.exists(BK+'Sprites/'+strip) else A)+'Sprites/'+strip
    orig=cv2.imread(src,-1); n=FR[strip]; fh=orig.shape[0]; fw=orig.shape[1]//n
    mim,(gn,glab,gst,_),K=key_master(A+'Sprites/'+master)
    frames=[]
    malpha=(mim[:,:,3]>0).astype(np.uint8)
    nlm,mlab,mst,_=cv2.connectedComponentsWithStats(cv2.dilate(malpha,np.ones((3,3),np.uint8)),8)
    for i in range(n):
        c=orig[:,i*fw:(i+1)*fw]; a=c[:,:,3]>200
        nl,lab,st,_=cv2.connectedComponentsWithStats(a.astype(np.uint8),8)
        big=st[1:,4].max(); keep=[j for j in range(1,nl) if st[j,4]>=0.15*big]
        main=np.isin(lab,keep)
        ys,xs=np.nonzero(main); bx0,by0,bx1,by1=xs.min(),ys.min(),xs.max()+1,ys.max()+1
        tpl=c[by0:by1,bx0:bx1,:3]; mk=main[by0:by1,bx0:bx1]
        sc,mx,my=locate(mim[:,:,:3],tpl,mk)
        ox,oy=mx-bx0,my-by0
        # seeds: main content + small comps near it (not stray edge fragments)
        dist=cv2.distanceTransform((~main).astype(np.uint8),cv2.DIST_L2,3)
        small=[j for j in range(1,nl) if j not in keep and dist[lab==j].min()<=30]
        def to_master(mask):
            yy,xx=np.nonzero(mask); yy=yy+oy; xx=xx+ox
            ok=(yy>=0)&(yy<mlab.shape[0])&(xx>=0)&(xx<mlab.shape[1])
            return mlab[yy[ok],xx[ok]]
        labs=set(np.unique(to_master(main)).tolist())
        for j in small:
            for L_ in np.unique(to_master(lab==j)):
                x_,y_,w_,h_,_=mst[L_]
                if x_>=ox-10 and y_>=oy-10 and x_+w_<=ox+fw+10 and y_+h_<=oy+fh+10: labs.add(int(L_))
        labs.discard(0); labs=np.array(sorted(labs))
        gm=np.isin(mlab,labs)&(malpha>0)
        frames.append(dict(ox=ox,oy=oy,score=float(sc),g=len(labs),mask=gm,orig=c))
    # extents relative to cell origin
    L=R=T=B=0
    for f in frames:
        if f['score']>3.0: continue
        ys,xs=np.nonzero(f['mask'])
        L=max(L,f['ox']-xs.min()); R=max(R,xs.max()+1-(f['ox']+fw)); T=max(T,f['oy']-ys.min()); B=max(B,ys.max()+1-(f['oy']+fh))
    L,R,T,B=[int(max(0,v))+2 if v>0 else 0 for v in (L,R,T,B)]
    if sym: L=R=max(L,R); T=B=max(T,B)
    nw,nh=fw+L+R,fh+T+B
    out=np.zeros((nh,nw*n,4),np.uint8)
    for i,f in enumerate(frames):
        if f['score']>3.0:
            out[T:T+fh,i*nw+L:i*nw+L+fw]=f['orig']; continue
        ys,xs=np.nonzero(f['mask'])
        ty=ys-f['oy']+T; tx=xs-f['ox']+L
        ok=(ty>=0)&(ty<nh)&(tx>=0)&(tx<nw)
        out[ty[ok],tx[ok]+i*nw]=mim[ys[ok],xs[ok]]
    return out,dict(strip=strip,n=n,old=(fw,fh),new=(nw,nh),pad=(L,R,T,B),scores=[round(f['score'],1) for f in frames],groups=[f['g'] for f in frames])
if __name__=='__main__':
    strip,master=sys.argv[1],sys.argv[2]
    out,info=reslice(strip,master)
    cv2.imwrite('rs_'+strip,out); print(json.dumps(info))
