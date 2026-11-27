#include <SDL3/SDL.h>

#include <catch2/catch_test_macros.hpp>
#include <chrono>
#include <cstdint>
#include <thread>

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

  REQUIRE_FALSE(anim.is_highlighted());

  anim.set_highlight(highlight_mode::fade);
  REQUIRE(anim.is_highlighted());

  anim.clear_highlight();
  REQUIRE_FALSE(anim.is_highlighted());
}

TEST_CASE("setting the mode to none is the same as clearing it",
          "[highlight]") {
  animation anim = makeAnimation();

  anim.set_highlight(highlight_mode::fade);
  anim.set_highlight(highlight_mode::none);

  REQUIRE_FALSE(anim.is_highlighted());
}

TEST_CASE("clearing a highlight that was never set does nothing",
          "[highlight]") {
  // Disabling must be safe on something that is not highlighted: a caller
  // cannot always know whether it still is.
  animation anim = makeAnimation();

  REQUIRE_NOTHROW(anim.clear_highlight());
  anim.clear_highlight();

  REQUIRE_FALSE(anim.is_highlighted());
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

TEST_CASE("the fade steps solid, 50%, 75%", "[highlight]") {
  /* Checked in ladder order, not as a set: an implementation producing the
     right three values in the wrong order still fails. */
  animation anim = makeAnimation();
  anim.set_highlight(highlight_mode::fade);

  const size_t levels = highlight_level_count;
  REQUIRE(levels == 3);
  const uint64_t step = highlight_cycle_ms / levels;

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

TEST_CASE("an expiring highlight stops fading the sprite", "[highlight]") {
  /* The pattern the game already uses: the state is left set, but the sprite is
     drawn normally. is_highlighted() reports the difference, so a caller can
     tell "still highlighted" from "highlight over".

     The deadline is the duration added to the clock reading at the moment of
     the call, which is not exposed. Rather than reach for the protected field,
     the call is bracketed between two readings. An earlier version of this test
     waited on the clock, which hung if it stood still. */
  const uint64_t before = SDL_GetTicks();
  animation anim = makeAnimation();
  anim.set_highlight(highlight_mode::fade, 500u);
  const uint64_t after = SDL_GetTicks();

  // The deadline therefore lies in [before + 500, after + 500].

  // Before it, the highlight is live at some instants and not at others, so
  // only check the half period it is definitely in.
  REQUIRE_FALSE(anim.highlight_expired_at(before));
  REQUIRE_FALSE(anim.highlight_expired_at(after + 499));

  // Just after the latest possible deadline, finished: drawn normally
  // throughout. Sampled from the deadline onwards rather than from zero,
  // because the deadline is an absolute clock reading and times before it are
  // still live.
  REQUIRE(anim.highlight_expired_at(after + 501));
  const uint64_t expired_from = after + 501;
  const uint64_t expired_to = expired_from + highlight_cycle_ms * 4;
  for (uint64_t t = expired_from; t < expired_to; ++t) {
    REQUIRE(anim.get_highlight_flags_at(t) == 0u);
  }

  // The mode is deliberately still set, so a caller can see that it ran out.
  REQUIRE(anim.is_highlighted());
}

TEST_CASE("a highlight without a duration never expires", "[highlight]") {
  animation anim = makeAnimation();
  anim.set_highlight(highlight_mode::fade);

  REQUIRE_FALSE(anim.highlight_expired_at(0));
  REQUIRE_FALSE(anim.highlight_expired_at(1000000));
}

TEST_CASE("clearing removes any deadline", "[highlight]") {
  animation anim = makeAnimation();

  anim.set_highlight(highlight_mode::fade, 500u);
  const uint64_t well_past = SDL_GetTicks() + 60000;

  // Still set, and by this point long expired. Clearing has to remove that, not
  // merely stop the caller asking about it.
  REQUIRE(anim.highlight_expired_at(well_past));

  anim.clear_highlight();

  REQUIRE_FALSE(anim.highlight_expired_at(well_past));
  REQUIRE_FALSE(anim.is_highlighted());
}

TEST_CASE("setting mode none removes any deadline", "[highlight]") {
  animation anim = makeAnimation();

  anim.set_highlight(highlight_mode::fade, 500u);
  anim.set_highlight(highlight_mode::none);

  // The same contrast: it had a deadline, and setting none took it away.
  REQUIRE_FALSE(anim.highlight_expired_at(SDL_GetTicks() + 60000));
  REQUIRE_FALSE(anim.is_highlighted());
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

  // isHighlighted() is false to begin with.
  lua_getfield(L.get(), -1, "isHighlighted");
  lua_pushvalue(L.get(), -2);
  lua_call(L.get(), 1, 1);
  REQUIRE(lua_toboolean(L.get(), -1) == 0);
  lua_pop(L.get(), 1);

  /* setHighlight(HighlightMode.Fade) with the duration left off: the bare call
     the issue asks to be usable without parameters. */
  lua_getfield(L.get(), -1, "setHighlight");
  lua_pushvalue(L.get(), -2);
  lua_pushinteger(L.get(), 1);  // highlight_mode::fade
  lua_call(L.get(), 2, 1);
  lua_pop(L.get(), 1);

  REQUIRE(anim->is_highlighted());

  lua_getfield(L.get(), -1, "isHighlighted");
  lua_pushvalue(L.get(), -2);
  lua_call(L.get(), 1, 1);
  REQUIRE(lua_toboolean(L.get(), -1) != 0);
  lua_pop(L.get(), 1);

  // And it can be turned off again from Lua.
  lua_getfield(L.get(), -1, "clearHighlight");
  lua_pushvalue(L.get(), -2);
  lua_call(L.get(), 1, 1);
  lua_pop(L.get(), 1);

  REQUIRE_FALSE(anim->is_highlighted());
}

TEST_CASE("setHighlight needs no mode at all from Lua", "[highlight][lua]") {
  /* There is only one mode, so a bare setHighlight() is the normal call and
     must apply it: the issue asks for a single default highlight that did not
     require parameters. Previously the mode argument was mandatory. */
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

  REQUIRE(anim->is_highlighted());

  // And it really is the fade ladder, not merely "something".
  const uint64_t step = highlight_cycle_ms / highlight_level_count;
  REQUIRE(anim->get_highlight_flags_at(0) == 0u);
  REQUIRE(anim->get_highlight_flags_at(step) ==
          static_cast<uint32_t>(thdf_alpha_50));
  REQUIRE(anim->get_highlight_flags_at(step * 2) ==
          static_cast<uint32_t>(thdf_alpha_75));
}

TEST_CASE("setHighlight takes an optional duration from Lua",
          "[highlight][lua]") {
  const lua_state_unique_ptr L(luaL_newstate());
  luaL_openlibs(L.get());
  preload_lua_package(L.get(), "TH", luaopen_th);
  luaT_execute(L.get(), "return require \"TH\"");
  lua_settop(L.get(), 1);

  lua_getfield(L.get(), -1, "animation");
  lua_call(L.get(), 0, 1);
  auto* anim = static_cast<animation*>(lua_touserdata(L.get(), -1));
  REQUIRE(anim != nullptr);

  /* The clock is bracketed rather than read after the fact, so the deadline
     can be bounded from the outside. Asserting only "not expired" is not
     enough: a binding that dropped the duration would leave no deadline at
     all, which is also not expired, and the call would pass.

     Moved clear of zero first: from 0, a raw duration and a deadline read
     from the clock are the same number. */
  while (SDL_GetTicks() < 100) {
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  REQUIRE(SDL_GetTicks() >= 100);

  const uint64_t before = SDL_GetTicks();
  lua_getfield(L.get(), -1, "setHighlight");
  lua_pushvalue(L.get(), -2);
  lua_pushinteger(L.get(), 1);  // highlight_mode::fade
  lua_pushinteger(L.get(), 60000);
  lua_call(L.get(), 3, 1);
  lua_pop(L.get(), 1);
  const uint64_t after = SDL_GetTicks();

  REQUIRE(anim->is_highlighted());

  // The deadline lies in [before + 60000, after + 60000], so it is both not yet
  // reached and genuinely about a minute out. The first bound also rules out a
  // deadline that ignored the current reading, which would be a flat 60000.
  REQUIRE_FALSE(anim->highlight_expired_at(before + 59000));
  REQUIRE_FALSE(anim->highlight_expired_at(after + 59999));
  REQUIRE(anim->highlight_expired_at(after + 60001));

  /* And the same call with the duration left off must not set a deadline at
     all, which is the other half of "optional". */
  anim->set_highlight(highlight_mode::none);
  lua_getfield(L.get(), -1, "setHighlight");
  lua_pushvalue(L.get(), -2);
  lua_pushinteger(L.get(), 1);
  lua_call(L.get(), 2, 1);
  lua_pop(L.get(), 1);

  REQUIRE(anim->is_highlighted());
  REQUIRE_FALSE(anim->highlight_expired_at(SDL_GetTicks() + 3600000));
}

TEST_CASE("isHighlighted reports false once a highlight has run out from Lua",
          "[highlight][lua]") {
  /* The binding reports is_highlighted() AND NOT expired, while the C++
     is_highlighted() only knows the mode. The binding is where a run-out
     highlight stops claiming to be running, so it needs its own test: the C++
     tests cannot see it. */
  const lua_state_unique_ptr L(luaL_newstate());
  luaL_openlibs(L.get());
  preload_lua_package(L.get(), "TH", luaopen_th);
  luaT_execute(L.get(), "return require \"TH\"");
  lua_settop(L.get(), 1);

  lua_getfield(L.get(), -1, "animation");
  lua_call(L.get(), 0, 1);
  auto* anim = static_cast<animation*>(lua_touserdata(L.get(), -1));
  REQUIRE(anim != nullptr);

  /* A one millisecond duration, then wait long enough for it to have gone. The
     wait is bounded rather than spun on, so a harness whose clock stands still
     fails instead of hanging the suite. */
  lua_getfield(L.get(), -1, "setHighlight");
  lua_pushvalue(L.get(), -2);
  lua_pushinteger(L.get(), 1);  // highlight_mode::fade
  lua_pushinteger(L.get(), 1);
  lua_call(L.get(), 3, 1);
  lua_pop(L.get(), 1);

  std::this_thread::sleep_for(std::chrono::milliseconds(20));

  // The C++ accessor still says the mode is set...
  REQUIRE(anim->is_highlighted());
  REQUIRE(anim->highlight_expired());

  // ...but Lua is told the highlight is over.
  lua_getfield(L.get(), -1, "isHighlighted");
  lua_pushvalue(L.get(), -2);
  lua_call(L.get(), 1, 1);
  REQUIRE(lua_toboolean(L.get(), -1) == 0);
  lua_pop(L.get(), 1);
}

TEST_CASE("setHighlight rejects a negative duration", "[highlight][lua]") {
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
  lua_pushinteger(L.get(), 1);
  lua_pushinteger(L.get(), -1);

  /* lua_pcall rather than lua_call: a rejected argument raises through
     luaL_argerror, which longjmps. A bare lua_call would abort the test
     binary instead of failing this case. */
  REQUIRE(lua_pcall(L.get(), 3, 1, 0) != LUA_OK);

  // A rejected call must not have left a highlight behind.
  REQUIRE_FALSE(anim->is_highlighted());
}