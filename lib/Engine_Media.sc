Engine_Media : CroneEngine {

    var synth;
    var loop_buf_a, loop_buf_b;
    var looper_a_in_bus, looper_a_out_bus;
    var looper_b_in_bus, looper_b_out_bus;
    var mediaNames, looperModuleA, looperModuleB;
    var env1_bus, env2_bus, link_bus, link_state, send_dummy_bus, send_own_buses;

    alloc {

        var mediumDsp, mediumBlend, mediumRead, loadLooper;

        loop_buf_a = Buffer.alloc(context.server, (48000 * 60), 2);
        loop_buf_b = Buffer.alloc(context.server, (48000 * 60), 2);
        looper_a_in_bus  = Bus.audio(context.server, 2);
        looper_a_out_bus = Bus.audio(context.server, 2);
        looper_b_in_bus  = Bus.audio(context.server, 2);
        looper_b_out_bus = Bus.audio(context.server, 2);
        mediaNames = [\bbd, \cas, \cd, \chip, \tape, \vinyl];
        link_bus = Bus.control(context.server, 3);
        link_state = ();
        env1_bus = Bus.control(context.server, 1);
        env2_bus = Bus.control(context.server, 1);

        context.server.sync;

        mediumDsp   = File.readAllString(PathName(this.class.filenameSymbol.asString).pathOnly ++ "medium_dsp.scd").interpret.value;
        mediumBlend = mediumDsp[\mediumBlend];
        mediumRead  = mediumDsp[\mediumRead];

        // ── Looper subsystem, shared, runtime-loaded, once per looper ──
        loadLooper = { |eng, idx, inBus, outBus, buf|
            var lp = PathName(eng.class.filenameSymbol.asString).pathOnly ++ "looper_engine.scd";
            File.readAllString(lp).interpret.value(eng, (
                mediaNames: mediaNames, mediumBlend: mediumBlend, mediumRead: mediumRead,
                server: context.server, mainSynth: { synth }, loopBuf: buf,
                looperInBus: inBus, looperOutBus: outBus, idx: idx, linkBus: link_bus, linkState: link_state
            ));
        };
        looperModuleA = loadLooper.value(this, 1, looper_a_in_bus, looper_a_out_bus, loop_buf_a);
        looperModuleB = loadLooper.value(this, 2, looper_b_in_bus, looper_b_out_bus, loop_buf_b);

        SynthDef(\media_silence, {
            arg bus_a = 0, bus_b = 0;
            ReplaceOut.ar(bus_a, DC.ar(0) ! 2);
            ReplaceOut.ar(bus_b, DC.ar(0) ! 2);
            Line.kr(0, 0, 0.02, doneAction: 2);
        }).add;

        // ── Main: input → A, A and/or input → B, A + B → output ──
        SynthDef(\media, {
            arg out_bus = 0, in_bus = 0, in_bus_r = 0,
                looper_a_in_bus_num = 0, looper_a_out_bus_num = 0,
                looper_b_in_bus_num = 0, looper_b_out_bus_num = 0,
                looper_b_input = 0,
                send_a_source = 3, send_a_level = 1.0, send_b_source = 3, send_b_level = 1.0,
                send_a_bus_num = 0, send_b_bus_num = 0,
                env1_attack = 0.05, env1_release = 0.05, env1_bus_num = 0,
                env2_attack = 0.05, env2_release = 0.05, env2_bus_num = 0;
            var sig, loop_a, loop_b, b_feed, full_out, send_a, send_b, env_src;
            send_a_level = Lag.kr(send_a_level, 0.05);
            send_b_level = Lag.kr(send_b_level, 0.05);
            env1_attack  = Lag.kr(env1_attack,  0.05);
            env1_release = Lag.kr(env1_release, 0.05);
            env2_attack  = Lag.kr(env2_attack,  0.05);
            env2_release = Lag.kr(env2_release, 0.05);
            sig = [In.ar(in_bus, 1), In.ar(in_bus_r, 1)];

            loop_a = InFeedback.ar(looper_a_out_bus_num, 2);
            loop_b = InFeedback.ar(looper_b_out_bus_num, 2);

            ReplaceOut.ar(looper_a_in_bus_num, sig);

            b_feed = [
                Select.ar(looper_b_input.round(1), [sig[0], loop_a[0], sig[0] + loop_a[0]]),
                Select.ar(looper_b_input.round(1), [sig[1], loop_a[1], sig[1] + loop_a[1]])
            ];
            ReplaceOut.ar(looper_b_in_bus_num, b_feed);

            Out.ar(out_bus, loop_a + loop_b);

            // ── amplitude followers (env mod sources) ────────────────────────
            env_src = sig[0];
            Out.kr(env1_bus_num, Amplitude.kr(env_src, env1_attack, env1_release).clip(0, 1));
            Out.kr(env2_bus_num, Amplitude.kr(env_src, env2_attack, env2_release).clip(0, 1));

            // ── fx send buses (per-send source + level) ──────────────────────
            full_out = sig + loop_a + loop_b;
            send_a = [
                Select.ar(send_a_source.round(1), [sig[0], loop_a[0], loop_b[0], full_out[0]]),
                Select.ar(send_a_source.round(1), [sig[1], loop_a[1], loop_b[1], full_out[1]])
            ] * send_a_level;
            send_b = [
                Select.ar(send_b_source.round(1), [sig[0], loop_a[0], loop_b[0], full_out[0]]),
                Select.ar(send_b_source.round(1), [sig[1], loop_a[1], loop_b[1], full_out[1]])
            ] * send_b_level;
            ReplaceOut.ar(send_a_bus_num, send_a);
            ReplaceOut.ar(send_b_bus_num, send_b);
        }).add;

        context.server.sync;

        Synth.head(context.xg, \media_silence, [
            \bus_a, looper_a_out_bus.index,
            \bus_b, looper_b_out_bus.index
        ]);

        send_dummy_bus = Bus.audio(context.server, 2);
        send_own_buses = [];
        synth = Synth(\media, [
            \out_bus,               context.out_b.index,
            \send_a_bus_num,        send_dummy_bus.index,
            \send_b_bus_num,        send_dummy_bus.index,
            \in_bus,                context.in_b[0].index,
            \in_bus_r,              context.in_b[1].index,
            \looper_a_in_bus_num,   looper_a_in_bus.index,
            \looper_a_out_bus_num,  looper_a_out_bus.index,
            \looper_b_in_bus_num,   looper_b_in_bus.index,
            \looper_b_out_bus_num,  looper_b_out_bus.index,
            \env1_bus_num,          env1_bus.index,
            \env2_bus_num,          env2_bus.index
        ], context.xg);

        // ── fx mod sends ─────────────────────────────────────────────
        this.addCommand("fx_attach", "", {
            var hw = [context.in_b[0].index, context.in_b[1].index, context.out_b.index, context.out_b.index + 1];
            var attach = { |key, name|
                var bus = topEnvironment[key];
                var i = if(bus.isNil) { nil } { if(bus.isKindOf(Bus)) { bus.index } { bus.asInteger } };
                case
                { i.isNil } { ("media: fx % - no fx mod found, send rests".format(name)).postln; send_dummy_bus.index }
                { [i, i + 1].sect(hw).notEmpty } {
                    var own = Bus.audio(context.server, 2);
                    send_own_buses = send_own_buses.add([key, bus, own]);
                    topEnvironment[key] = own;
                    ("media: fx % - the fx mod's bus % overlaps the norns input/output, its plugins read bus % while media runs".format(name, i, own.index)).postln;
                    own.index
                }
                { ("media: fx % -> bus %".format(name, i)).postln; i }
            };
            synth.set(\send_a_bus_num, attach.(\sendA, "send A"), \send_b_bus_num, attach.(\sendB, "send B"));
        });

        this.addCommand("looper_b_input", "f", { |msg| synth.set(\looper_b_input, msg[1]) });

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
        looperModuleA[\free].value;
        looperModuleB[\free].value;
        loop_buf_a.free;
        loop_buf_b.free;
        looper_a_in_bus.free;
        looper_a_out_bus.free;
        looper_b_in_bus.free;
        looper_b_out_bus.free;
        link_bus.free;
        send_dummy_bus.free;
        send_own_buses.do { |e| topEnvironment[e[0]] = e[1]; e[2].free };
        env1_bus.free;
        env2_bus.free;
    }
}
