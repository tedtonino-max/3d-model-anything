#include "SurfaceCore.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <new>
#include <vector>

namespace {
struct V { float x=0,y=0,z=0; V operator+(V b)const{return{x+b.x,y+b.y,z+b.z};} V operator-(V b)const{return{x-b.x,y-b.y,z-b.z};} V operator*(float s)const{return{x*s,y*s,z*s};} };
static_assert(sizeof(V)==3*sizeof(float),"packed vectors");
float dot(V a,V b){return a.x*b.x+a.y*b.y+a.z*b.z;}
V cross(V a,V b){return{a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
V unit(V a){float n=std::sqrt(dot(a,a));return n>1e-8f?a*(1/n):V{};}
bool finite(V p){return std::isfinite(p.x)&&std::isfinite(p.y)&&std::isfinite(p.z);}
struct Quad { std::array<int,4> v{{-1,-1,-1,-1}}; bool reverse=false,flat=false; V normal; };
}
struct DFVolume { int nx,ny,nz; float step; V origin; std::vector<float> sdf; std::vector<uint16_t> weight;
 size_t at(int x,int y,int z)const{return(size_t(z)*ny+y)*nx+x;}
};
struct DFMesh { std::vector<V> p,n;std::vector<uint32_t> indices;int merged=0; };

extern "C" DFVolume *DFCreateVolume(int nx,int ny,int nz,float step,float ox,float oy,float oz){
 if(nx<3||ny<3||nz<3||nx>512||ny>512||nz>512||!(step>=0.003f&&step<=0.1f)||!finite({ox,oy,oz}))return nullptr;
 const size_t count=size_t(nx)*ny*nz;if(count>8000000)return nullptr;
 try{return new DFVolume{nx,ny,nz,step,{ox,oy,oz},std::vector<float>(count,1),std::vector<uint16_t>(count,0)};}catch(...){return nullptr;}
}
extern "C" void DFDestroyVolume(DFVolume *v){delete v;}
extern "C" int DFIntegrate(DFVolume *v,const float *d,const uint8_t *c,int w,int h,const float *m,float fx,float fy,float cx,float cy){
 if(!v||!d||!c||!m||w<3||h<3||!(fx>0&&fy>0))return 0;
 for(int i=0;i<16;i++)if(!std::isfinite(m[i]))return 0;
 int accepted=0;const float baseTrunc=v->step*4;
 // Bilinear interpolation only inside locally continuous measured surfaces.
 // At silhouettes/depth jumps we retain the measured pixel and a narrower band,
 // instead of averaging foreground feet into the floor or background.
 for(int z=0;z<v->nz;z++)for(int y=0;y<v->ny;y++){
  const float wy=v->origin.y+y*v->step,wz=v->origin.z+z*v->step;
  float px=m[0]*v->origin.x+m[4]*wy+m[8]*wz+m[12];
  float py=m[1]*v->origin.x+m[5]*wy+m[9]*wz+m[13];
  float pz=-(m[2]*v->origin.x+m[6]*wy+m[10]*wz+m[14]);
  for(int x=0;x<v->nx;x++,px+=m[0]*v->step,py+=m[1]*v->step,pz-=m[2]*v->step){
   if(pz<=0.15f||pz>5)continue;const float u=fx*px/pz+cx,t=-fy*py/pz+cy;
   if(u<0||t<0||u>=w-1||t>=h-1)continue;int ix=int(u),iy=int(t),i=iy*w+ix;
   if(c[i]!=2||!std::isfinite(d[i])||d[i]<=0.15f||d[i]>5)continue;
   float measured=d[i],trunc=baseTrunc;
   const float a=d[i],b=d[i+1],e=d[i+w],f=d[i+w+1];
   const float lo=std::min({a,b,e,f}),hi=std::max({a,b,e,f});
   if(c[i+1]==2&&c[i+w]==2&&c[i+w+1]==2&&lo>0.15f&&std::isfinite(hi)&&hi-lo<0.025f){
    const float du=u-ix,dv=t-iy;measured=(a*(1-du)+b*du)*(1-dv)+(e*(1-du)+f*du)*dv;
   }else{trunc=v->step*2;}
   float distance=measured-pz;if(distance< -trunc)continue;
   const size_t id=v->at(x,y,z);const float sample=std::min(1.f,distance/trunc);const auto weight=v->weight[id];
   if(weight==65535)continue;v->sdf[id]=(v->sdf[id]*weight+sample)/(weight+1);v->weight[id]=weight+1;accepted++;
  }
 }
 return accepted;
}
namespace {
constexpr int corner[8][3]={{0,0,0},{1,0,0},{0,1,0},{1,1,0},{0,0,1},{1,0,1},{0,1,1},{1,1,1}};
constexpr int edges[12][2]={{0,1},{2,3},{4,5},{6,7},{0,2},{1,3},{4,6},{5,7},{0,4},{1,5},{2,6},{3,7}};
V gradient(const float s[8],V p){
 float gx=0,gy=0,gz=0;
 for(int z=0;z<2;z++)for(int y=0;y<2;y++)gx+=(s[1+2*y+4*z]-s[2*y+4*z])*(y?p.y:1-p.y)*(z?p.z:1-p.z);
 for(int z=0;z<2;z++)for(int x=0;x<2;x++)gy+=(s[x+2+4*z]-s[x+4*z])*(x?p.x:1-p.x)*(z?p.z:1-p.z);
 for(int y=0;y<2;y++)for(int x=0;x<2;x++)gz+=(s[x+2*y+4]-s[x+2*y])*(x?p.x:1-p.x)*(y?p.y:1-p.y);
 return unit({gx,gy,gz});
}
V solve(float a[3][3],float b[3],V fallback){
 float m[3][4];for(int r=0;r<3;r++){for(int c=0;c<3;c++)m[r][c]=a[r][c];m[r][3]=b[r];}
 for(int c=0;c<3;c++){
  int best=c;for(int r=c+1;r<3;r++)if(std::abs(m[r][c])>std::abs(m[best][c]))best=r;
  if(std::abs(m[best][c])<1e-7f)return fallback;
  for(int k=c;k<4;k++)std::swap(m[c][k],m[best][k]);float scale=m[c][c];for(int k=c;k<4;k++)m[c][k]/=scale;
  for(int r=0;r<3;r++)if(r!=c){float factor=m[r][c];for(int k=c;k<4;k++)m[r][k]-=factor*m[c][k];}
 }
 V p{m[0][3],m[1][3],m[2][3]};if(!finite(p)||p.x<0||p.x>1||p.y<0||p.y>1||p.z<0||p.z>1)return fallback;return p;
}
void triangle(DFMesh &m,int a,int b,int c,bool reverse){
 if(a<0||b<0||c<0||a==b||b==c||a==c)return;
 if(dot(cross(m.p[b]-m.p[a],m.p[c]-m.p[a]),cross(m.p[b]-m.p[a],m.p[c]-m.p[a]))<1e-16f)return;
 m.indices.push_back(uint32_t(a));m.indices.push_back(uint32_t(reverse?c:b));m.indices.push_back(uint32_t(reverse?b:c));
}
void emitLayer(DFMesh &mesh,std::vector<Quad> &qs,int w,int h,float tolerance,bool simplify){
 std::vector<uint8_t> used(qs.size(),0);
 for(int y=0;y<h;y++)for(int x=0;x<w;x++){
  int id=y*w+x;const Quad &q=qs[id];if(used[id]||q.v[0]<0)continue;
  const V origin=mesh.p[q.v[0]],normal=q.normal;
  auto matches=[&](int xx,int yy){const int j=yy*w+xx;const Quad &r=qs[j];if(used[j]||r.v[0]<0||!r.flat||r.reverse!=q.reverse||dot(normal,r.normal)<0.999f)return false;
   for(int v:r.v)if(std::abs(dot(mesh.p[v]-origin,normal))>tolerance)return false;return true;};
  int width=1,height=1;
  if(simplify&&q.flat){
   while(width<32&&x+width<w&&matches(x+width,y))width++;
   while(height<32&&y+height<h){bool ok=true;for(int i=0;i<width;i++)if(!matches(x+i,y+height)){ok=false;break;}if(!ok)break;height++;}
  }
  if(width*height<=4){used[id]=1;triangle(mesh,q.v[0],q.v[1],q.v[2],q.reverse);triangle(mesh,q.v[0],q.v[2],q.v[3],q.reverse);continue;}
  std::vector<int> boundary;boundary.reserve(2*(width+height));
  for(int i=0;i<width;i++)boundary.push_back(qs[y*w+x+i].v[0]);
  for(int j=0;j<height;j++)boundary.push_back(qs[(y+j)*w+x+width-1].v[1]);
  for(int i=width-1;i>=0;i--)boundary.push_back(qs[(y+height-1)*w+x+i].v[2]);
  for(int j=height-1;j>=0;j--)boundary.push_back(qs[(y+j)*w+x].v[3]);
  V center{};for(int v:boundary)center=center+mesh.p[v];center=center*(1.f/boundary.size());
  const int mid=int(mesh.p.size());mesh.p.push_back(center);mesh.n.push_back(normal);
  for(size_t i=0;i<boundary.size();i++)triangle(mesh,mid,boundary[i],boundary[(i+1)%boundary.size()],q.reverse);
  for(int j=0;j<height;j++)for(int i=0;i<width;i++)used[(y+j)*w+x+i]=1;
  mesh.merged+=width*height;
 }
}
}
extern "C" DFMesh *DFExtractMesh(const DFVolume *v,int minimum,int simplify){
 if(!v)return nullptr;minimum=std::max(1,minimum);
 try {
  auto mesh=new DFMesh();std::vector<int> cells(v->sdf.size(),-1);
  for(int z=0;z<v->nz-1;z++)for(int y=0;y<v->ny-1;y++)for(int x=0;x<v->nx-1;x++){
   float s[8];bool good=true,positive=false,negative=false;
   for(int i=0;i<8;i++){size_t id=v->at(x+corner[i][0],y+corner[i][1],z+corner[i][2]);if(v->weight[id]<minimum){good=false;break;}s[i]=v->sdf[id];positive|=s[i]>=0;negative|=s[i]<0;}
   if(!good||!positive||!negative)continue;
   V sum{},normal{};int count=0;float a[3][3]={{0}},b[3]={0};
   for(const auto &edge:edges){int i=edge[0],j=edge[1];if((s[i]<0)==(s[j]<0))continue;
    float t=s[i]/(s[i]-s[j]);V p{float(corner[i][0])+(corner[j][0]-corner[i][0])*t,float(corner[i][1])+(corner[j][1]-corner[i][1])*t,float(corner[i][2])+(corner[j][2]-corner[i][2])*t};
    V n=gradient(s,p);float ns[3]={n.x,n.y,n.z},rhs=dot(n,p);
    for(int r=0;r<3;r++){b[r]+=ns[r]*rhs;for(int c=0;c<3;c++)a[r][c]+=ns[r]*ns[c];}
    sum=sum+p;normal=normal+n;count++;
   }
   if(!count)continue;V centroid=sum*(1.f/count);float cs[3]={centroid.x,centroid.y,centroid.z};
   for(int r=0;r<3;r++){a[r][r]+=0.01f;b[r]+=0.01f*cs[r];}
   V q=solve(a,b,centroid);V world=v->origin+(V{float(x),float(y),float(z)}+q)*v->step;
   cells[v->at(x,y,z)]=int(mesh->p.size());mesh->p.push_back(world);mesh->n.push_back(unit(normal));
  }
  // Surface-normal constraints place vertices at intersections of planes rather
  // than rounding every corner. Coplanar quad regions are merged DURING meshing;
  // their complete boundary is retained so neighbouring curved cells stay joined.
  for(int axis=0;axis<3;axis++){
   int dims[3]={v->nx,v->ny,v->nz},u=(axis+1)%3,t=(axis+2)%3,w=dims[u]-2,h=dims[t]-2;
   for(int layer=0;layer<dims[axis]-1;layer++){
    std::vector<Quad> qs(size_t(w)*h);
    for(int b=0;b<h;b++)for(int a=0;a<w;a++){
     int c[3]={0,0,0};c[axis]=layer;c[u]=a+1;c[t]=b+1;int next[3]={c[0],c[1],c[2]};next[axis]++;
     const size_t lo=v->at(c[0],c[1],c[2]),hi=v->at(next[0],next[1],next[2]);
     if(v->weight[lo]<minimum||v->weight[hi]<minimum||(v->sdf[lo]<0)==(v->sdf[hi]<0))continue;
     Quad q;q.reverse=v->sdf[lo]>=0;
     const int offsets[4][2]={{-1,-1},{0,-1},{0,0},{-1,0}};
     bool valid=true;for(int i=0;i<4;i++){int p[3]={c[0],c[1],c[2]};p[u]+=offsets[i][0];p[t]+=offsets[i][1];q.v[i]=cells[v->at(p[0],p[1],p[2])];if(q.v[i]<0)valid=false;}
     if(!valid)continue;q.normal=unit(mesh->n[q.v[0]]+mesh->n[q.v[1]]+mesh->n[q.v[2]]+mesh->n[q.v[3]]);q.flat=true;
     for(int id:q.v)if(dot(q.normal,mesh->n[id])<0.999f)q.flat=false;
     qs[size_t(b)*w+a]=q;
    }
    emitLayer(*mesh,qs,w,h,v->step*0.2f,simplify);
   }
  }
  return mesh;
 }catch(...){return nullptr;}
}
extern "C" void DFDestroyMesh(DFMesh *m){delete m;}
extern "C" int DFVertexCount(const DFMesh *m){return m?int(m->p.size()):0;}
extern "C" int DFTriangleCount(const DFMesh *m){return m?int(m->indices.size()/3):0;}
extern "C" const float *DFPositions(const DFMesh *m){return m&&!m->p.empty()?&m->p[0].x:nullptr;}
extern "C" const float *DFNormals(const DFMesh *m){return m&&!m->n.empty()?&m->n[0].x:nullptr;}
extern "C" const uint32_t *DFIndices(const DFMesh *m){return m&&!m->indices.empty()?m->indices.data():nullptr;}
extern "C" int DFMergedPlanarQuads(const DFMesh *m){return m?m->merged:0;}
