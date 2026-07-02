Engine_Media : CroneEngine {

    var synth;
    var loop_buf;
    var looper_in_bus, looper_out_bus, mediaNames, looperModule;
    var env1_bus, env2_bus;

    alloc {

        var mediumDsp, mediumBlend, mediumRead;

        loop_buf = Buffer.alloc(context.server, (48000 * 40), 2);
        looper_in_bus  = Bus.audio(context.server, 2);
        looper_out_bus = Bus.audio(context.server, 2);
        mediaNames = [\bbd, \cas, \cd, \chip, \tape, \vinyl];
        env1_bus = Bus.control(context.server, 1);
        env2_bus = Bus.control(context.server, 1);

        context.server.sync;

        mediumDsp   = File.readAllString(PathName(this.class.filenameSymbol.asString).pathOnly ++ "medium_dsp.scd").interpret.value;
        mediumBlend = mediumDsp[\mediumBlend];
        mediumRead  = mediumDsp[\mediumRead];

        // ── Looper subsystem (SynthDefs + commands), shared, runtime-loaded ──
        looperModule = { |eng|
            var lp = PathName(eng.class.filenameSymbol.asString).pathOnly ++ "looper_engine.scd";
            File.readAllString(lp).interpret.value(eng, (
                mediaNames: mediaNames, mediumBlend: mediumBlend, mediumRead: mediumRead,
                server: context.server, mainSynth: { synth }, loopBuf: loop_buf,
                looperInBus: looper_in_bus, looperOutBus: looper_out_bus
            ));
        }.value(this);

        // ── Main: input → looper_in_bus, looper_out_bus → output (loop only) ──
        SynthDef(\media, {
            arg out_bus = 0, in_bus = 0, in_bus_r = 0,
                looper_in_bus_num = 0, looper_out_bus_num = 0,
                send_a_source = 2, send_a_level = 1.0, send_b_source = 2, send_b_level = 1.0,
                env1_attack = 0.05, env1_release = 0.05, env1_bus_num = 0,
                env2_attack = 0.05, env2_release = 0.05, env2_bus_num = 0;
            var sig, loop_out, full_out, send_a, send_b, env_src;
            send_a_level = Lag.kr(send_a_level, 0.05);
            send_b_level = Lag.kr(send_b_level, 0.05);
            env1_attack  = Lag.kr(env1_attack,  0.05);
            env1_release = Lag.kr(env1_release, 0.05);
            env2_attack  = Lag.kr(env2_attack,  0.05);
            env2_release = Lag.kr(env2_release, 0.05);
            sig = [In.ar(in_bus, 1), In.ar(in_bus_r, 1)];
            ReplaceOut.ar(looper_in_bus_num, sig);
            loop_out = InFeedback.ar(looper_out_bus_num, 2);
            Out.ar(out_bus, loop_out);

            // ── amplitude followers (env mod sources) ────────────────────────
            env_src = sig[0];
            Out.kr(env1_bus_num, Amplitude.kr(env_src, env1_attack, env1_release).clip(0, 1));
            Out.kr(env2_bus_num, Amplitude.kr(env_src, env2_attack, env2_release).clip(0, 1));

            // ── fx send buses (per-send source + level) ──────────────────────
            // Output == full audible output = monitored input + loop (media has
            // no dry/amp path of its own).
            full_out = sig + loop_out;
            send_a = [
                Select.ar(send_a_source.round(1), [sig[0], loop_out[0], full_out[0]]),
                Select.ar(send_a_source.round(1), [sig[1], loop_out[1], full_out[1]])
            ] * send_a_level;
            send_b = [
                Select.ar(send_b_source.round(1), [sig[0], loop_out[0], full_out[0]]),
                Select.ar(send_b_source.round(1), [sig[1], loop_out[1], full_out[1]])
            ] * send_b_level;
            if(~sendA.notNil) { ReplaceOut.ar(~sendA, send_a) };
            if(~sendB.notNil) { ReplaceOut.ar(~sendB, send_b) };
        }).add;

        context.server.sync;

        synth = Synth(\media, [
            \out_bus,            context.out_b.index,
            \in_bus,             context.in_b[0].index,
            \in_bus_r,           context.in_b[1].index,
            \looper_in_bus_num,  looper_in_bus.index,
            \looper_out_bus_num, looper_out_bus.index,
            \env1_bus_num,       env1_bus.index,
            \env2_bus_num,       env2_bus.index
        ], context.xg);

        this.addCommand("fx_send_a_source", "f", { |msg| synth.set(\send_a_source, msg[1]) });
        this.addCommand("fx_send_a_level",  "f", { |msg| synth.set(\send_a_level,  msg[1]) });
        this.addCommand("fx_send_b_source", "f", { |msg| synth.set(\send_b_source, msg[1]) });
        this.addCommand("fx_send_b_level",  "f", { |msg| synth.set(\send_b_level,  msg[1]) });

        this.addCommand("env1_attack",  "f", { |msg| synth.set(\env1_attack,  msg[1]) });
        this.addCommand("env1_release", "f", { |msg| synth.set(\env1_release, msg[1]) });
        this.addCommand("env2_attack",  "f", { |msg| synth.set(\env2_attack,  msg[1]) });
        this.addCommand("env2_release", "f", { |msg| synth.set(\env2_release, msg[1]) });

        this.addPoll("env1_value", { env1_bus.getSynchronous });
        this.addPoll("env2_value", { env2_bus.getSynchronous });
    }

    free {
        synth.free;
        loop_buf.free;
        looperModule[\free].value;
        looper_in_bus.free;
        looper_out_bus.free;
        env1_bus.free;
        env2_bus.free;
    }
}
