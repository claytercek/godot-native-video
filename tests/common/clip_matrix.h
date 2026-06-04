#pragma once
// -----------------------------------------------------------------------
// clip_matrix.h — tiny, dependency-free reader for the real-clip format
// matrix manifest (tests/fixtures/matrix/matrix.list).
//
// Shared by the per-platform backend coverage tests (AVF on macOS, MF on
// Windows). It parses the whitespace-separated plain-text manifest — NOT the
// JSON — so the headless test binaries pull in no JSON dependency.
//
// Each row describes one real encoded clip and the decode results the
// coverage test asserts:
//   file  width  height  fps  frames  audio_channels  audio_rate
//
// The clips themselves are Git-LFS-tracked binaries. If LFS has not pulled
// them (or ffmpeg hasn't regenerated them) the per-clip file simply won't
// exist; the coverage test treats that as "skip with WARN", never a failure,
// mirroring how the synthetic-clip tests degrade when ffmpeg is absent.
// -----------------------------------------------------------------------

#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <vector>

namespace clip_matrix {

struct Clip {
	std::string file; // basename, e.g. "h264_30_mp4.mp4"
	int width = 0;
	int height = 0;
	int fps = 0;
	int frames = 0;
	int audio_channels = 0;
	int audio_rate = 0;
};

inline bool file_exists(const std::string &p) {
	struct stat st;
	return ::stat(p.c_str(), &st) == 0;
}

// Repo root: REPO_ROOT env override, else "." (scons runs tests from root).
inline std::string repo_root() {
	if (const char *env = std::getenv("REPO_ROOT")) {
		return std::string(env);
	}
	return ".";
}

inline std::string matrix_dir() {
	return repo_root() + "/tests/fixtures/matrix";
}

// Parse matrix.list. Returns empty if the manifest is absent or unreadable.
inline std::vector<Clip> load() {
	std::vector<Clip> clips;
	const std::string manifest = matrix_dir() + "/matrix.list";
	std::ifstream in(manifest);
	if (!in) {
		return clips;
	}
	std::string line;
	while (std::getline(in, line)) {
		// Strip a trailing CR (manifest may arrive with CRLF on Windows).
		if (!line.empty() && line.back() == '\r') {
			line.pop_back();
		}
		// Skip blanks and comments.
		std::size_t first = line.find_first_not_of(" \t");
		if (first == std::string::npos || line[first] == '#') {
			continue;
		}
		std::istringstream ss(line);
		Clip c;
		if (ss >> c.file >> c.width >> c.height >> c.fps >> c.frames >> c.audio_channels >> c.audio_rate) {
			clips.push_back(c);
		}
	}
	return clips;
}

// Absolute path to a clip's binary file.
inline std::string clip_path(const Clip &c) {
	return matrix_dir() + "/" + c.file;
}

// True if a clip file looks like a Git-LFS pointer (text stub) rather than the
// real binary — i.e. LFS smudge has not run. Such a clip must be skipped, not
// decoded. LFS pointers begin with "version https://git-lfs".
inline bool is_lfs_pointer(const std::string &path) {
	std::ifstream in(path, std::ios::binary);
	if (!in) {
		return false;
	}
	char buf[64] = {0};
	in.read(buf, sizeof(buf) - 1);
	return std::string(buf).rfind("version https://git-lfs", 0) == 0;
}

} // namespace clip_matrix
