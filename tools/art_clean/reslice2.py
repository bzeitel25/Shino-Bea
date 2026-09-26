import cv2,numpy as np,os,sys,re,json
sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
from reslice import key_master,locate,FR,A,BK
def load_strip(strip):
    src=(BK if os.path.exists(BK+'Sprites/'+strip) else A)+'Sprites/'+strip
    return cv2.imread(src,-1)
def monster(master, strips, margin=0.25, dil=3):
    mim,raw,K=key_master(A+'Sprites/'+master)
    malpha=(mim[:,:,3]>0).astype(np.uint8)
    nlm,mlab,mst,_=cv2.connectedComponentsWithStats(cv2.dilate(malpha,np.ones((dil,dil),np.uint8)),8)
    H,W=malpha.shape
    F=[]
    for s in strips:
        o=load_strip(s); cur=cv2.imread(A+'Sprites/'+s,-1); n=FR[s]; fh=o.shape[0]; fw=o.shape[1]//n
        for i in range(n):
            c=o[:,i*fw:(i+1)*fw]; a=c[:,:,3]>200
            nl,lab,st,_=cv2.connectedComponentsWithStats(a.astype(np.uint8),8)
            jb=1+int(st[1:,4].argmax()); big=st[jb,4]
            bx,by,bw,bh=st[jb,:4]
            def touches(j): return st[j,0]==0 or st[j,1]==0 or st[j,0]+st[j,2]==fw or st[j,1]+st[j,3]==fh
            keep=[j for j in range(1,nl) if st[j,4]>=0.15*big and (not touches(j) or st[j,4]>=0.5*big or j==jb)]
            main=np.isin(lab,keep)
            ys,xs=np.nonzero(main); x0,y0,x1,y1=xs.min(),ys.min(),xs.max()+1,ys.max()+1
            sc,mx,my=locate(raw,c[y0:y1,x0:x1,:3],main[y0:y1,x0:x1])
            ox,oy=mx-x0,my-y0
            # drop secondary parts whose master blob mostly lives outside this cell (neighbour poses)
            good=[]
            for j in keep:
                if j==jb: good.append(j); continue
                yy,xx=np.nonzero(lab==j); yy=yy+oy; xx=xx+ox
                okk=(yy>=0)&(yy<H)&(xx>=0)&(xx<W)
                ls=np.unique(mlab[yy[okk],xx[okk]]); ls=ls[ls>0]
                bad=False
                for L_ in ls:
                    bx_,by_,bw_,bh_,_=mst[L_]
                    over=max(0,ox-bx_)+max(0,bx_+bw_-(ox+fw)); overy=max(0,oy-by_)+max(0,by_+bh_-(oy+fh))
                    if over>0.25*fw or overy>0.25*fh: bad=True
                if not bad: good.append(j)
            keep=good
            main=np.isin(lab,keep)
            mm=np.zeros((H,W),bool); yy,xx=np.nonzero(main); yy+=oy; xx+=ox
            ok=(yy>=0)&(yy<H)&(xx>=0)&(xx<W); mm[yy[ok],xx[ok]]=True
            dist=cv2.distanceTransform((~main).astype(np.uint8),cv2.DIST_L2,3)
            small=np.zeros_like(main)
            for j in range(1,nl):
                if j not in keep and dist[lab==j].min()<=30 and not (st[j,0]==0 or st[j,1]==0 or st[j,0]+st[j,2]==fw or st[j,1]+st[j,3]==fh): small|=lab==j
            F.append(dict(strip=s,i=i,fw=fw,fh=fh,ox=ox,oy=oy,score=float(sc),main=mm,small=small,orig=cur[:,i*fw:(i+1)*fw]))
    res={}
    for f in F:
        if f['score']>3.0: f['mask']=None; continue
        ox,oy,fw,fh=f['ox'],f['oy'],f['fw'],f['fh']
        labs=set(np.unique(mlab[f['main']]).tolist())
        yy,xx=np.nonzero(f['small']); yy+=oy; xx+=ox; ok=(yy>=0)&(yy<H)&(xx>=0)&(xx<W)
        labs|=set(np.unique(mlab[yy[ok],xx[ok]]).tolist()); labs.discard(0)
        gm=np.isin(mlab,sorted(labs))&(malpha>0)
        mx_,my_=int(margin*fw),int(margin*fh)
        win=np.zeros_like(gm); win[max(0,oy-my_):oy+fh+my_,max(0,ox-mx_):ox+fw+mx_]=True
        gm&=win
        # ownership: a pixel belongs to the pose whose main content is nearest
        y0w,y1w,x0w,x1w=max(0,oy-my_),min(H,oy+fh+my_),max(0,ox-mx_),min(W,ox+fw+mx_)
        own=cv2.distanceTransform((~f['main'][y0w:y1w,x0w:x1w]).astype(np.uint8),cv2.DIST_L2,3)
        for g in F:
            if g is f: continue
            gmn=g['main'][y0w:y1w,x0w:x1w]
            if not gmn.any(): continue
            inter=(g['main']&f['main']).sum()
            if inter>0.3*min(g['main'].sum(),f['main'].sum()): continue
            other=cv2.distanceTransform((~gmn).astype(np.uint8),cv2.DIST_L2,3)
            sub=gm[y0w:y1w,x0w:x1w]; sub&=~(other<own)
        # drop tiny islands produced by clipping (not seeded)
        nl2,l2,s2,_=cv2.connectedComponentsWithStats(gm.astype(np.uint8),8)
        keepm=np.zeros_like(gm)
        for j in range(1,nl2):
            comp=l2==j
            if (comp&f['main']).any() or s2[j,4]>=40 and (cv2.dilate(comp.astype(np.uint8),np.ones((61,61),np.uint8)).astype(bool)&f['main']).any(): keepm|=comp
        f['mask']=keepm
    out={}
    for s in strips:
        fr=[f for f in F if f['strip']==s]; fw,fh=fr[0]['fw'],fr[0]['fh']; n=len(fr)
        L=R=T=B=0
        for f in fr:
            if f['mask'] is None: continue
            ys,xs=np.nonzero(f['mask'])
            L=max(L,f['ox']-xs.min()); R=max(R,xs.max()+1-(f['ox']+fw)); T=max(T,f['oy']-ys.min()); B=max(B,ys.max()+1-(f['oy']+fh))
        L=R=int(max(L,R)); T=B=int(max(T,B))
        if L>0: L=R=L+2
        if T>0: T=B=T+2
        nw,nh=fw+L+R,fh+T+B
        img=np.zeros((nh,nw*n,4),np.uint8)
        for f in fr:
            i=f['i']
            if f['mask'] is None:
                img[T:T+fh,i*nw+L:i*nw+L+fw]=f['orig']; continue
            ys,xs=np.nonzero(f['mask'])
            img[ys-f['oy']+T, xs-f['ox']+L+i*nw]=mim[ys,xs]
        out[s]=(img,dict(old=(fw,fh),new=(nw,nh),pad=(L,T),scores=[round(f['score'],1) for f in fr]))
    return out,mim,K
if __name__=='__main__':
    master=sys.argv[1]; strips=sys.argv[2:]
    out,_,K=monster(master,strips)
    for s,(img,info) in out.items():
        cv2.imwrite('rs_'+s,img); print(s,json.dumps(info))
