#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct DFVolume DFVolume;
typedef struct DFMesh DFMesh;
DFVolume *DFCreateVolume(int nx,int ny,int nz,float voxel,float ox,float oy,float oz);
void DFDestroyVolume(DFVolume *volume);
int DFIntegrate(DFVolume *volume,const float *depth,const uint8_t *confidence,int width,int height,
                const float *worldToCamera,float fx,float fy,float cx,float cy);
DFMesh *DFExtractMesh(const DFVolume *volume,int minimumObservations,int simplifyPlanes);
void DFDestroyMesh(DFMesh *mesh);
int DFVertexCount(const DFMesh *mesh);
int DFTriangleCount(const DFMesh *mesh);
const float *DFPositions(const DFMesh *mesh);
const float *DFNormals(const DFMesh *mesh);
const uint32_t *DFIndices(const DFMesh *mesh);
int DFMergedPlanarQuads(const DFMesh *mesh);
#ifdef __cplusplus
}
#endif
