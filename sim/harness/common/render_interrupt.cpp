#include "render_interrupt.h"

#include <csignal>

namespace render {
namespace {

volatile std::sig_atomic_t g_interrupt_requested = 0;

void handle_interrupt(int) {
  g_interrupt_requested = 1;
}

}  // namespace

void install_interrupt_handler() {
  std::signal(SIGINT, handle_interrupt);
}

bool interrupt_requested() {
  return g_interrupt_requested != 0;
}

}  // namespace render
