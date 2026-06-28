#include "core/map/map_manager.hpp"
#include "core/map/tiles_map_generator.h"

#include "core/map/map_io.hpp"
#include "common/logger/logger.h"
#include "core/map/json.hpp"

#include <boost/filesystem.hpp>
#include <condition_variable>
#include <cstdlib>
#include <fstream>
#include <mutex>
#include <sstream>
#include <thread>

#include "yaml-cpp/yaml.h"

namespace fs = boost::filesystem;

namespace ros_gui_backend {

static std::string GetHomeDir() {
  if (const char* h = std::getenv("HOME")) {
    return std::string(h);
  }
  return std::string();
}

MapManager::MapManager() : map_available_(false) {
  std::string home = GetHomeDir();
  map_root_ = home.empty() ? ".maps" : home + "/.maps";
  default_map_update_worker_ = std::thread(&MapManager::DefaultMapUpdateWorkerLoop, this);
}

MapManager::~MapManager() {
  {
    std::lock_guard<std::mutex> lock(default_map_update_mu_);
    stop_default_map_update_worker_ = true;
  }
  default_map_update_cv_.notify_all();
  if (default_map_update_worker_.joinable()) {
    default_map_update_worker_.join();
  }
}

std::string MapManager::GetMapRoot() const {
  return map_root_;
}

std::string MapManager::GetMapDir(const std::string& map_name) const {
  if (map_name.empty()) return map_root_;
  return map_root_ + "/" + map_name;
}

std::string MapManager::GetTilesDir(const std::string& map_name) const {
  return GetMapDir(map_name) + "/tiles";
}

std::string MapManager::GetCurrentMapName() const {
  std::string path = map_root_ + "/current_map";
  std::ifstream ifs(path);
  if (!ifs) return std::string("map");
  std::string name;
  if (!std::getline(ifs, name)) return std::string("map");
  size_t end = name.find_last_not_of(" \t\r\n");
  if (end != std::string::npos) name.resize(end + 1);
  else if (!name.empty()) {
    size_t start = name.find_first_not_of(" \t\r\n");
    name = (start != std::string::npos) ? name.substr(start) : "";
  }
  return name;
}

bool MapManager::SetCurrentMapName(const std::string& map_name) {
  std::string path = map_root_ + "/current_map";
  fs::create_directories(fs::path(map_root_));
  std::ofstream ofs(path);
  if (!ofs) {
    LOGGER_ERROR("Failed to write current_map: {}", path);
    return false;
  }
  ofs << map_name;
  return true;
}

std::string MapManager::ResolveCurrentMapYamlPath() const {
  std::string current = GetCurrentMapName();
  if (current.empty()) {
    return std::string();
  }
  std::string yaml_path = GetMapDir(current) + "/" + current + ".yaml";
  if (fs::exists(yaml_path)) {
    return yaml_path;
  }
  return std::string();
}

static bool ReadMapMetaFromYaml(const std::string& yaml_path, double& resolution,
    double& origin_x, double& origin_y, double& origin_yaw,
    uint32_t& width, uint32_t& height) {
  try {
    YAML::Node doc = YAML::LoadFile(yaml_path);
    resolution = doc["resolution"].as<double>();
    auto origin = doc["origin"].as<std::vector<double>>();
    if (origin.size() >= 3) {
      origin_x = origin[0];
      origin_y = origin[1];
      origin_yaw = origin[2];
    }
    if (doc["width"].IsDefined() && doc["height"].IsDefined()) {
      width = doc["width"].as<int>();
      height = doc["height"].as<int>();
      return true;
    }
    std::string img_path = doc["image"].as<std::string>();
    if (img_path[0] != '/') {
      size_t pos = yaml_path.find_last_of("/\\");
      img_path = (pos != std::string::npos ? yaml_path.substr(0, pos + 1) : "") + img_path;
    }
    std::ifstream ifs(img_path, std::ios::binary);
    if (!ifs) return false;
    std::string line;
    std::getline(ifs, line);
    if (line != "P5") return false;
    while (std::getline(ifs, line) && line[0] == '#') {}
    std::istringstream ss(line);
    int w = 0, h = 0;
    if (ss >> w >> h) {
      width = w;
      height = h;
      return true;
    }
  } catch (...) {}
  return false;
}

static std::vector<std::string> GetAllMapNames(const std::string& map_root) {
  std::vector<std::string> names;
  try {
    if (!fs::exists(map_root) || !fs::is_directory(map_root)) return names;
    for (fs::directory_iterator it(map_root); it != fs::directory_iterator(); ++it) {
      if (!fs::is_directory(it->status())) continue;
      std::string name = it->path().filename().string();
      if (name.empty() || name[0] == '.') continue;
      if (fs::exists(map_root + "/" + name + "/"+name+".yaml")) {
        names.push_back(name);
      }
    }
  } catch (...) {}
  return names;
}

bool MapManager::Initialize() {
  default_tiles_dir_ = GetTilesDir("map");
  std::string init_yaml = ResolveCurrentMapYamlPath();
  if (!init_yaml.empty() && LoadMapFromYaml(init_yaml) != LOAD_MAP_SUCCESS) {
    LOGGER_ERROR("Failed to load map: {}", init_yaml);
  }
  return true;
}

std::vector<std::string> MapManager::ListMapNames() const {
  return GetAllMapNames(map_root_);
}

bool MapManager::ReadYamlMapMeta(const std::string& yaml_path, double& resolution, double& origin_x,
    double& origin_y, double& origin_yaw, uint32_t& width, uint32_t& height) const {
  return ReadMapMetaFromYaml(yaml_path, resolution, origin_x, origin_y, origin_yaw, width, height);
}

bool MapManager::TryBuildCurrentTilesMetaJson(std::string* out_json) const {
  if (!map_available_ || out_json == nullptr) {
    return false;
  }
  TilesMapGenerator gen;
  int max_zoom = gen.GetMaxZoom(current_map_.width, current_map_.height, extra_zoom_levels_);
  nlohmann::json j;
  j["resolution"] = current_map_.resolution;
  j["origin_x"] = current_map_.origin_x;
  j["origin_y"] = current_map_.origin_y;
  j["width"] = current_map_.width;
  j["height"] = current_map_.height;
  j["max_zoom"] = max_zoom;
  j["extra_zoom_levels"] = extra_zoom_levels_;
  *out_json = j.dump();
  return true;
}

MapOperationResult MapManager::ApplyMapEditFromQuery(const std::string& session_id,
    const std::string& map_name, const std::string& source_map_name,
    const std::string& topology_json, const std::string& obstacle_edits_json) {
  LOGGER_INFO("map edit map_name={}", map_name);
  if (session_id.empty() || map_name.empty() || topology_json.empty() || obstacle_edits_json.empty()) {
    return {false, "missing query params"};
  }
  std::string base_dir = GetMapDir(map_name);
  try {
    const std::string yaml_path = base_dir + "/" + map_name + ".yaml";
    OccupancyGridData target_map_data;
    if (loadMapFromYaml(yaml_path, target_map_data) != LOAD_MAP_SUCCESS) {
      std::string source_name = source_map_name.empty() ? GetCurrentMapName() : source_map_name;
      if (source_name.empty()) {
        return {false, "map not found"};
      }
      const std::string source_yaml_path = GetMapDir(source_name) + "/" + source_name + ".yaml";
      if (loadMapFromYaml(source_yaml_path, target_map_data) != LOAD_MAP_SUCCESS) {
        return {false, "map not found"};
      }
    }
    fs::create_directories(fs::path(base_dir));
    if (!fs::exists(GetTilesDir(map_name))) {
      fs::create_directories(fs::path(GetTilesDir(map_name)));
    }
    auto obstacle_edits = nlohmann::json::parse(obstacle_edits_json);
    if (!obstacle_edits.is_object()) {
      return {false, "obstacle_edits_json must be a JSON object"};
    }
    for (auto it = obstacle_edits.begin(); it != obstacle_edits.end(); ++it) {
      const std::string key = it.key();
      if (!it.value().is_number_integer()) {
        LOGGER_ERROR("Invalid edit value for cellIndex: {}, value type is not integer", key);
        continue;
      }
      const int8_t edit_value = static_cast<int8_t>(it.value().get<int>());
      int64_t cell_index = 0;
      try {
        cell_index = std::stoll(key);
      } catch (const std::exception& e) {
        LOGGER_ERROR("Invalid cell index: {} error: {}", key, e.what());
        continue;
      }
      if (cell_index < 0 || static_cast<size_t>(cell_index) >= target_map_data.data.size()) {
        continue;
      }
      target_map_data.data[static_cast<size_t>(cell_index)] = edit_value;
      LOGGER_INFO("Apply obstacle edit cell_index={} edit_value={}", cell_index,
          static_cast<int>(edit_value));
    }
    SaveParameters save_params;
    std::string map_file_base = base_dir + "/" + map_name;
    save_params.map_file_name = map_file_base;
    save_params.image_format = "pgm";
    save_params.free_thresh = 0.25;
    save_params.occupied_thresh = 0.65;
    save_params.mode = MapMode::Trinary;
    if (!saveMapToFile(target_map_data, save_params)) {
      return {false, "failed to save map"};
    }
    auto topology_obj = nlohmann::json::parse(topology_json).get<TopologyMap>();
    saveTopologyMapToJson(topology_obj, map_file_base + ".topology");
    TilesMapGenerator gen;
    if (!gen.GenerateAllTilesToDir(target_map_data, GetTilesDir(map_name), extra_zoom_levels_)) {
      return {false, "failed to regenerate tiles"};
    }
    const bool is_current_map = (map_name == GetCurrentMapName());
    if (is_current_map) {
      current_map_ = target_map_data;
      topo_map_ = topology_obj;
      map_available_ = true;
    }
    return {true, {}};
  } catch (const std::exception& e) {
    return {false, std::string(e.what())};
  }
}

MapOperationResult MapManager::ApplyTilesExtraZoomFromJson(const std::string& body_json) {
  if (!map_available_) {
    return {false, "map not available"};
  }
  try {
    auto j = nlohmann::json::parse(body_json);
    int v = j.value("extra_zoom_levels", extra_zoom_levels_);
    if (v < 0 || v > 8) {
      return {false, "extra_zoom_levels must be 0-8"};
    }
    extra_zoom_levels_ = v;
    std::string cur = GetCurrentMapName();
    RegenerateTiles(cur.empty() ? default_tiles_dir_ : GetTilesDir(cur));
    return {true, {}};
  } catch (const std::exception&) {
    return {false, "invalid json"};
  }
}

MapOperationResult MapManager::ApplyTilesExtraZoomForMapYaml(const std::string& map_name,
    const std::string& body_json) {
  std::string yaml_path = GetMapDir(map_name) + "/map.yaml";
  if (!fs::exists(yaml_path)) {
    return {false, "map not found"};
  }
  try {
    auto j = nlohmann::json::parse(body_json);
    int v = j.value("extra_zoom_levels", extra_zoom_levels_);
    if (v < 0 || v > 8) {
      return {false, "extra_zoom_levels must be 0-8"};
    }
    extra_zoom_levels_ = v;
    (void)LoadMapFromYaml(yaml_path, false);
    return {true, {}};
  } catch (const std::exception&) {
    return {false, "invalid json"};
  }
}

void MapManager::RegenerateTiles(const std::string& output_dir) {
  if (!map_available_) return;
  TilesMapGenerator gen;
  if (gen.GenerateAllTilesToDir(current_map_, output_dir, extra_zoom_levels_)) {
    LOGGER_INFO("Tiles regenerated to {}", output_dir);
  }
}

LOAD_MAP_STATUS MapManager::LoadMapFromYaml(const std::string& yaml_file, bool update_current_state) {
  OccupancyGridData loaded_map;
  LOAD_MAP_STATUS status = loadMapFromYaml(yaml_file, loaded_map);
  if (status != LOAD_MAP_SUCCESS) {
    return status;
  }
  std::string json_file = yaml_file;
  size_t pos = json_file.rfind(".yaml");
  if (pos != std::string::npos) {
    json_file.replace(pos, 5, ".topology");
  }
  if (update_current_state) {
    topo_map_file_name_ = json_file;
    LoadTopologyMapFromJson(json_file, topo_map_);
    current_map_ = loaded_map;
    map_available_ = true;

    // ── 自动补生成缺失的 tiles ──────────────────────────────────
    // 从 yaml 路径的父目录名提取地图名，例如：
    //   /home/wheeltec/.maps/map_test01/map_test01.yaml  →  map_test01
    std::string map_name;
    try {
      map_name = fs::path(yaml_file).parent_path().filename().string();
    } catch (...) {}
    if (!map_name.empty()) {
      const std::string tiles_dir = GetTilesDir(map_name);
      bool tiles_missing = true;
      try {
        if (fs::exists(tiles_dir) && fs::is_directory(tiles_dir)) {
          for (fs::recursive_directory_iterator it(tiles_dir), end_it;
               it != end_it; ++it) {
            if (fs::is_regular_file(it->status())) {
              tiles_missing = false;
              break;
            }
          }
        }
      } catch (...) {}
      if (tiles_missing) {
        LOGGER_INFO("LoadMapFromYaml: tiles missing for {}, auto generating...", map_name);
        fs::create_directories(fs::path(tiles_dir));
        TilesMapGenerator gen;
        if (gen.GenerateAllTilesToDir(current_map_, tiles_dir, extra_zoom_levels_)) {
          LOGGER_INFO("LoadMapFromYaml: tiles generated to {}", tiles_dir);
        }
      }
    }
    // ────────────────────────────────────────────────────────────
  }
  return LOAD_MAP_SUCCESS;
}

void MapManager::UpdateDefaultMap(const OccupancyGridData& data) {
  {
    std::lock_guard<std::mutex> lock(default_map_update_mu_);
    wait_handle_default_map_ = data;
    has_pending_default_map_update_ = true;
  }
  default_map_update_cv_.notify_one();
}

void MapManager::DefaultMapUpdateWorkerLoop() {
  while (!stop_default_map_update_worker_) {
    OccupancyGridData pending_data;
    {
      std::unique_lock<std::mutex> lock(default_map_update_mu_);
      default_map_update_cv_.wait(lock, [this]() {
        return stop_default_map_update_worker_ || has_pending_default_map_update_;
      });
      if (stop_default_map_update_worker_) {
        return;
      }
      pending_data = wait_handle_default_map_;
      has_pending_default_map_update_ = false;
    }
    ProcessDefaultMapUpdate(pending_data);
  }
}

void MapManager::ProcessDefaultMapUpdate(const OccupancyGridData& data) {
  const std::string default_map_name = "map";
  fs::create_directories(fs::path(GetTilesDir(default_map_name)));
  SaveParameters save_params;
  save_params.map_file_name = GetMapDir(default_map_name) + "/map";
  save_params.image_format = "pgm";
  save_params.free_thresh = 0.25;
  save_params.occupied_thresh = 0.65;
  save_params.mode = MapMode::Trinary;
  if (!saveMapToFile(data, save_params)) {
    LOGGER_ERROR("Failed to persist default map to {}", save_params.map_file_name);
    return;
  }
  TilesMapGenerator gen;
  if (gen.GenerateAllTilesToDir(data, GetTilesDir(default_map_name), extra_zoom_levels_)) {
    LOGGER_INFO("Default map tiles regenerated to {}", GetTilesDir(default_map_name));
  }

  const std::string current_name = GetCurrentMapName();
  if (current_name.empty() || current_name == default_map_name) {
    current_map_ = data;
    map_available_ = true;
  }
}




}  // namespace ros_gui_backend
