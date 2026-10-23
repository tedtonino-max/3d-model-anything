# Local detail focus on the original scanner

This adds a painted detail pass to the existing Wes Bos iPhone/iPad app. The original RoomPlan/ARKit geometry, coverage renderer, library and reconstruction/export pipeline are preserved. No DepthForge fusion or accumulated per-frame triangulation is included.

During scanning, choose **Detail schilderen**, paint a surface, and choose **Meet dit detail**. Orange shows the 3D selection. Guidance asks for 25–70 cm and additional angles. The capture prioritizes these views for photos, and admits closer-spaced depth viewpoints (up to about 8/s, still bounded by the existing writer and thermal/memory budget). A detail ID links those records to the selected world-space region. Room exports include the region metadata in `details/room-N.json`.

The detail panel separately reports the native mesh's local face count and median edge length. Edge length describes tessellation density, not physical accuracy, completeness or a successful reconstruction. The extension cannot command ARKit to return a prescribed geometric resolution. Closer capture can supply more evidence; detailed geometry is not guaranteed. Photos alone do not prove a finer mesh.

Two local reconstruction experiments on the user's existing poof scan did not yield reliable thin legs. They are not shipped as geometry generators. The scan data remains local. This revision preserves the working original app and adds targeted acquisition and explicit measurement rather than claiming that the missing legs have been recovered.

Checks: pure policy tests, original app simulator self-tests (including export/history/preview checks and new detail serialization checks), and device Release build in the existing GitHub workflow. Live LiDAR quality still requires physical-device validation.
