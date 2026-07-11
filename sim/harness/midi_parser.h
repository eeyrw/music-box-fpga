#pragma once

#include "render_types.h"

#include <string>
#include <vector>

namespace render {

std::vector<NoteEvent> parse_midi(const std::string& path);
std::vector<NoteEvent> default_melody();

}  // namespace render
