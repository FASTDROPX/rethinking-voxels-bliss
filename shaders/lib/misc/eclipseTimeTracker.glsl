// =============================================================================
//  ECLIPSE TIME TRACKER  (Iteration 36)
// -----------------------------------------------------------------------------
//  100% self-contained cinematic time-transition clock. The Iris engine-side
//  smooth() uniforms are ABANDONED for the animation timeline: they cannot be
//  flushed from the shader, so back-to-back /time commands collapsed their
//  (sin, cos) average into a degenerate low-magnitude state that accumulated
//  across triggers. This module replaces them with explicit, fully-owned state
//  in a tiny persistent custom image and a timeline driven purely by
//  frameTimeCounter.
//
//  STATE (image.eclipse_time_img, 2x1 RGBA32F, never cleared between frames):
//    texel (0,0): x = init magic (1234.5 -> state is valid)
//                 y = previous frame's RAW native sun angle   (delta tracker)
//                 z = frameTimeCounter at the last detected jump (t = 0)
//                 w = visual sun angle at that jump (start of the routine)
//    texel (1,0): x = current eased VISUAL sun angle, turns in [0,1)
//                 y = last frame's frameTimeCounter (reset/wrap guard)
//
//  WRITER: EclipseUpdateTimeState(), executed by EXACTLY ONE compute invocation
//  per frame (shadowcomp.csh, the earliest always-on compute pass -- it hosts
//  RV's voxel SDF update and runs in every dimension every frame). Compiled
//  only where CSH is defined (all compute wrappers are #version 430).
//
//  READERS: everything else, through EclipseVisualSunAngle() -- a single
//  texelFetch, which is core GLSL 1.30, so the 49 #version 130 composite-style
//  programs read it exactly like the 430 ones. No SSBO is involved (SSBOs do
//  not exist below GLSL 430, which is why the state lives in an image).
//
//  FOOLPROOF DELTA-TRIGGER: each frame the writer compares the raw native sun
//  angle with the previous frame's sample (wrap-aware). Normal play advances
//  ~0.000014 turns per frame; anything beyond ECLIPSE_TIME_JUMP_THRESHOLD is a
//  /time set, bed sleep, time plugin or dimension switch -> the routine
//  restarts FRESH from t = 0, from the CURRENT visual angle. Because the state
//  is fully overwritten on every trigger, nothing can accumulate: the 1st, 2nd
//  and 100th jump run the identical routine. A jump landing mid-glide simply
//  re-bases the start at the current visual position -- continuous by
//  construction, so there is no freeze and no snap, ever.
// =============================================================================
#ifndef INCLUDE_ECLIPSE_TIME_TRACKER
#define INCLUDE_ECLIPSE_TIME_TRACKER

// ~96 ticks (4.8 in-game seconds). Steady play is 4 orders of magnitude below
// this; every real time command is far above it.
#define ECLIPSE_TIME_JUMP_THRESHOLD 0.004

uniform sampler2D eclipse_time_sampler;

// Read interface: the eased visual sun angle maintained by the tracker.
float EclipseVisualSunAngle() {
    return texelFetch(eclipse_time_sampler, ivec2(1, 0), 0).r;
}

#ifdef CSH
    layout(rgba32f) uniform image2D eclipse_time_img;

    // Runs once per frame from a single shadowcomp invocation.
    void EclipseUpdateTimeState() {
        float nativeAngle = fract(sunAngle);
        float nowT = frameTimeCounter;
        float dur = max(TIME_TRANSITION_SPEED, 0.05); // slider 0.0 == instant

        vec4 s0 = imageLoad(eclipse_time_img, ivec2(0, 0));
        vec4 s1 = imageLoad(eclipse_time_img, ivec2(1, 0));

        if (s0.x != 1234.5 || nowT < s1.y - 0.5) {
            // Cold start, shader reload, or frameTimeCounter reset/wrap:
            // HARD FLUSH of every accumulation variable back to baseline --
            // the routine is marked complete and the visual clock stands
            // exactly on native time, as if the pack had just loaded.
            s0 = vec4(1234.5, nativeAngle, nowT - 2.0 * dur, nativeAngle);
            s1 = vec4(nativeAngle, nowT, 0.0, 0.0);
        } else {
            // Delta-trigger on the RAW native angle (wrap-aware shortest arc).
            float dNative = fract(nativeAngle - s0.y + 0.5) - 0.5;
            if (abs(dNative) > ECLIPSE_TIME_JUMP_THRESHOLD) {
                s0.z = nowT; // a completely fresh routine starts at t = 0
                s0.w = s1.x; // ... from the CURRENT visual angle (seamless
                             //     hand-over if a jump lands mid-glide)
            }
            s0.y = nativeAngle;

            // Timeline: pure frameTimeCounter. t reaches 1 after EXACTLY
            // TIME_TRANSITION_SPEED seconds; the ease-in-out lands the visual
            // angle on the LIVE native target (sampled fresh every frame, so
            // normal time advance during the glide is folded in) and then
            // tracks it 1:1 until the next trigger.
            float t = clamp((nowT - s0.z) / dur, 0.0, 1.0);
            float tS = t * t * (3.0 - 2.0 * t);
            float gap = fract(nativeAngle - s0.w + 0.5) - 0.5;
            s1.x = fract(s0.w + gap * tS);
            s1.y = nowT;
        }

        imageStore(eclipse_time_img, ivec2(0, 0), s0);
        imageStore(eclipse_time_img, ivec2(1, 0), s1);
    }
#endif

#endif // INCLUDE_ECLIPSE_TIME_TRACKER
