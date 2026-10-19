package static

import "github.com/gin-gonic/gin"

const AssetsPath = "/api/assets"

// RegisterAssetRoutes serves the files in dir under AssetsPath. An empty dir
// leaves the route unmounted, so an environment without the volume answers 404
// exactly as it would for a file nobody has uploaded yet.
func RegisterAssetRoutes(r gin.IRouter, dir string, limit gin.HandlerFunc) {
	if dir == "" {
		return
	}
	// Listing is off: the app learns what exists from manifest.json, and a
	// browsable index of the private set is not something to hand out.
	r.Group(AssetsPath, limit).StaticFS("/", gin.Dir(dir, false))
}
