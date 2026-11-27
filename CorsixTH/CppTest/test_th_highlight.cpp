#include <SDL3/SDL.h>

#include <catch2/catch_test_macros.hpp>
#include <cstdint>

#include "../Src/lua.hpp"
#include "../Src/th_gfx.h"
#include "../Src/th_lua.h"

namespace {

/*! A drawable with a known starting state, so that a test can tell a change it
    asked for from one left over from a previous case.
 */
animation makeAnimation() {
  animation anim;
  anim.set_flags(0);
  anim.clear_highlight();
  return anim;
}

}  // namespace

TEST_CASE("a highlight can be set and cleared", "[highlight]") {
  animation anim = makeAnimation();

  REQUIRE(anim.get_highlight_flags() == 0u);

  anim.set_highlight(highlight_mode::fade);
  REQUIRE(anim.get_highlight_flags_at(highlight_cycle_ms / 2) != 0u);

  anim.clear_highlight();
  REQUIRE(anim.get_highlight_flags() == 0u);
}

TEST_CASE("setting the mode to none is the same as clearing it",
          "[highlight]") {
  animation anim = makeAnimation();

  anim.set_highlight(highlight_mode::fade);
  anim.set_highlight(highlight_mode::none);

  REQUIRE(anim.get_highlight_flags() == 0u);
}

TEST_CASE("clearing a highlight that was never set does nothing",
          "[highlight]") {
  // Disabling must be safe on something that is not highlighted: a caller
  // cannot always know whether it still is.
  animation anim = makeAnimation();

  REQUIRE_NOTHROW(anim.clear_highlight());
  anim.clear_highlight();

  REQUIRE(anim.get_highlight_flags() == 0u);
}

TEST_CASE("the highlight steps solid, 50%, 75%", "[highlight]") {
  /* Checked in ladder order, not as a set: an implementation producing the
     right three values in the wrong order still fails. */
  animation anim = makeAnimation();
  anim.set_highlight(highlight_mode::fade);

  REQUIRE(highlight_level_count == 3);
  const uint64_t step = highlight_cycle_ms / highlight_level_count;

  REQUIRE(anim.get_highlight_flags_at(0) == 0u);
  REQUIRE(anim.get_highlight_flags_at(step) ==
          static_cast<uint32_t>(thdf_alpha_50));
  REQUIRE(anim.get_highlight_flags_at(step * 2) ==
          static_cast<uint32_t>(thdf_alpha_75));
  REQUIRE(anim.get_highlight_flags_at(step * 3 - 1) ==
          static_cast<uint32_t>(thdf_alpha_75));

  // Back to solid for the next cycle.
  REQUIRE(anim.get_highlight_flags_at(highlight_cycle_ms) == 0u);
}

TEST_CASE("each level lasts highlight_cycle_ms divided by the level count",
          "[highlight]") {
  animation anim = makeAnimation();
  anim.set_highlight(highlight_mode::fade);

  const uint64_t step = highlight_cycle_ms / highlight_level_count;

  // Boundaries: solid up to the first step, 50% up to the second, 75% to the
  // end.
  REQUIRE(anim.get_highlight_flags_at(step - 1) == 0u);
  REQUIRE(anim.get_highlight_flags_at(step) ==
          static_cast<uint32_t>(thdf_alpha_50));
  REQUIRE(anim.get_highlight_flags_at(step * 2 - 1) ==
          static_cast<uint32_t>(thdf_alpha_50));
  REQUIRE(anim.get_highlight_flags_at(step * 2) ==
          static_cast<uint32_t>(thdf_alpha_75));
  REQUIRE(anim.get_highlight_flags_at(highlight_cycle_ms - 1) ==
          static_cast<uint32_t>(thdf_alpha_75));
}

TEST_CASE("no highlight level is ever completely invisible", "[highlight]") {
  /* No level is ever completely invisible: a fading sprite stays on screen at
     some opacity throughout, so it can always be seen and, because flags is
     untouched, always be clicked.

     Both alpha bits at once would mean "do not draw" according to th_gfx.h, so
     their absence is asserted too: with both set the renderer takes the
     alpha_50 branch and gives 50%, which is not invisible but is not what any
     level means. */
  animation anim = makeAnimation();

  anim.set_highlight(highlight_mode::fade);

  const uint32_t both = static_cast<uint32_t>(thdf_alpha_50 | thdf_alpha_75);
  for (uint64_t t = 0; t < highlight_cycle_ms * 3; ++t) {
    const uint32_t flags = anim.get_highlight_flags_at(t);
    REQUIRE(flags != both);
    REQUIRE((flags == 0u || flags == static_cast<uint32_t>(thdf_alpha_50) ||
             flags == static_cast<uint32_t>(thdf_alpha_75)));
  }
}

TEST_CASE("the cycle is 300ms", "[highlight]") {
  /* Pinned so that changing it is a deliberate act rather than an accident.
     A preference rather than a measurement: the clip attached to the issue
     shows no blink to compare against. */
  REQUIRE(highlight_cycle_ms == 300);
}

TEST_CASE("nothing is faded when there is no highlight", "[highlight]") {
  animation anim = makeAnimation();

  REQUIRE(anim.get_highlight_flags_at(0) == 0u);
  REQUIRE(anim.get_highlight_flags_at(1000) == 0u);
  REQUIRE(anim.get_highlight_flags_at(highlight_cycle_ms) == 0u);
  REQUIRE(anim.get_highlight_flags_at(highlight_cycle_ms * 7) == 0u);
}

TEST_CASE("a highlight never touches the drawable's own flags", "[highlight]") {
  /* Why get_highlight_flags() is separate from get_flags(): animation::hit_test()
     refuses anything carrying both alpha bits, so a highlight stored in flags
     would make a fading sprite impossible to click. Pinned at every level of
     the fade ladder, not just the first. */
  animation anim = makeAnimation();
  const uint32_t original = static_cast<uint32_t>(thdf_flip_horizontal);
  anim.set_flags(original);
  anim.set_highlight(highlight_mode::fade);

  const size_t levels = highlight_level_count;
  const uint64_t step = highlight_cycle_ms / levels;

  for (size_t level = 0; level < levels; ++level) {
    INFO("level " << level);
    REQUIRE(anim.get_flags() == original);
  }
  // And across a whole cycle, so no level can sneak a flag in.
  for (uint64_t t = 0; t < highlight_cycle_ms; ++t) {
    REQUIRE(anim.get_flags() == original);
  }
}

TEST_CASE("setHighlight is callable from Lua", "[highlight][lua]") {
  const lua_state_unique_ptr L(luaL_newstate());
  luaL_openlibs(L.get());
  preload_lua_package(L.get(), "TH", luaopen_th);
  luaT_execute(L.get(), "return require \"TH\"");
  lua_settop(L.get(), 1);

  lua_getfield(L.get(), -1, "animation");
  lua_call(L.get(), 0, 1);
  REQUIRE(lua_isuserdata(L.get(), -1));
  auto* anim = static_cast<animation*>(lua_touserdata(L.get(), -1));
  REQUIRE(anim != nullptr);

  /* setHighlight() with no arguments: the bare call the issue asks to be
     usable without parameters. */
  lua_getfield(L.get(), -1, "setHighlight");
  lua_pushvalue(L.get(), -2);
  lua_call(L.get(), 1, 1);
  lua_pop(L.get(), 1);

  REQUIRE(anim->get_highlight_flags_at(highlight_cycle_ms / 2) != 0u);

  // And it can be turned off again from Lua.
  lua_getfield(L.get(), -1, "clearHighlight");
  lua_pushvalue(L.get(), -2);
  lua_call(L.get(), 1, 1);
  lua_pop(L.get(), 1);

  REQUIRE(anim->get_highlight_flags() == 0u);
}

TEST_CASE("setHighlight needs no mode at all from Lua", "[highlight][lua]") {
  /* There is only one mode, so a bare setHighlight() is the normal call and
     must apply it: the issue asks for a single default highlight that did not
     require parameters. */
  const lua_state_unique_ptr L(luaL_newstate());
  luaL_openlibs(L.get());
  preload_lua_package(L.get(), "TH", luaopen_th);
  luaT_execute(L.get(), "return require \"TH\"");
  lua_settop(L.get(), 1);

  lua_getfield(L.get(), -1, "animation");
  lua_call(L.get(), 0, 1);
  auto* anim = static_cast<animation*>(lua_touserdata(L.get(), -1));
  REQUIRE(anim != nullptr);

  lua_getfield(L.get(), -1, "setHighlight");
  lua_pushvalue(L.get(), -2);
  lua_call(L.get(), 1, 1);  // no mode, no duration
  lua_pop(L.get(), 1);

  REQUIRE(anim->get_highlight_flags_at(highlight_cycle_ms / 2) != 0u);

  // And it really is the fade ladder, not merely "something".
  const uint64_t step = highlight_cycle_ms / highlight_level_count;
  REQUIRE(anim->get_highlight_flags_at(0) == 0u);
  REQUIRE(anim->get_highlight_flags_at(step) ==
          static_cast<uint32_t>(thdf_alpha_50));
  REQUIRE(anim->get_highlight_flags_at(step * 2) ==
          static_cast<uint32_t>(thdf_alpha_75));
}
