// Module: fifo_almost_full_2cycle_read_tb
//
// Description: Flat (no class hierarchy) testbench for
// fifo_almost_full_2cycle_read, written in the same style as
// bit_diff_tb_no_hierarchy: everything lives in one module, stimulus / monitors
// / scoreboard are plain `initial` processes talking over mailboxes, and the
// knobs that change *how* the test runs are module parameters rather than a
// class factory. A FIFO has no go/done handshake, so the pieces map across
// like this:
//
//   bit_diff                      fifo_almost_full_2cycle_read
//   ------------------------      --------------------------------------------
//   generator -> driver_mailbox   same (fifo_item = one cycle of wr/rd stimulus)
//   start_monitor                 wr_monitor -- observes accepted writes
//   done_monitor                  rd_monitor -- samples rd_data two ticks after
//                                 an accepted read (F13)
//   model() function              reference_model process. A FIFO is stateful,
//                                 so the model has to be a process holding a
//                                 queue + a 2-stage read pipeline, not a pure
//                                 function.
//   scoreboard                    scoreboard (data + ordering, F14) plus the
//                                 reference_model's per-cycle flag checks
//                                 (F1-F12)
//
// This is the Questa tier from docs/verification_plan.md Sec.3: covergroups
// (Sec.3 "Covergroups") + the 5 SVA (Sec.3 "SVA"). It uses classes, mailboxes
// and covergroups, so it is deliberately NOT Verilator-compatible -- the fast
// tier lives in tb/cocotb/test_fifo.py. Every check and cover bin below is
// tagged with the spec IDs (F1..F16) from docs/fifo_spec.md Sec.4 so the
// traceability matrix in docs/verification_plan.md Sec.1 stays checkable by
// grep rather than by memory.
//
// ---------------------------------------------------------------------------
// NOTE (spec/RTL wording mismatch on almost_full -- RTL is authoritative):
//   fifo_spec.md Sec.2/F10 word it as  occupancy >= ALMOST_FULL_THRESHOLD
//   rtl/...sv:70 implements            almost_full = (count_r == THRESHOLD)
// The RTL is the intended contract: almost_full is an exact-match occupancy
// flag, so with THRESHOLD < DEPTH it pulses at exactly that occupancy and
// deasserts again above it -- including at full. The two readings coincide only
// at the ALMOST_FULL_THRESHOLD == DEPTH default (count can never exceed DEPTH),
// which is why the default instantiation hides the difference entirely.
// The reference model below therefore uses `==`. docs/fifo_spec.md Sec.2 and
// F10 are the things that need rewording, not this file.
// AF_MODEL_USES_GTE exists only to re-run against the old `>=` reading if that
// decision is ever revisited.
// ---------------------------------------------------------------------------

module fifo_almost_full_2cycle_read_tb #(
    parameter int NUM_TESTS = 1000,
    parameter int WIDTH = 8,
    parameter int DEPTH = 32,
    parameter int ALMOST_FULL_THRESHOLD = DEPTH,

    // 0 = model almost_full as `count == THRESHOLD` (the RTL's intended
    // behaviour, and the default). 1 = the older `count >= THRESHOLD` wording
    // still in fifo_spec.md Sec.2/F10; see the note in the file header.
    parameter bit AF_MODEL_USES_GTE = 1'b0,

    // Cross-check DUT wr_addr_r/rd_addr_r against the model's indices (F2/F3/F9).
    // Set to 0 if hierarchical access into the DUT is unavailable.
    parameter bit CHECK_INTERNAL_PTRS = 1'b1,

    // Drive random garbage on wr_data when wr_en is low, to prove the DUT
    // qualifies its write data (the FIFO analogue of bit_diff's
    // TOGGLE_INPUTS_WHILE_ACTIVE).
    parameter bit TOGGLE_INPUTS_WHILE_IDLE = 1'b1,

    parameter bit LOG_WR_MONITOR = 1'b0,
    parameter bit LOG_RD_MONITOR = 1'b0,
    parameter bit LOG_TESTS = 1'b1,

    // Idle gap inserted between random-stress transactions. Defaults keep the
    // gap at 0 for ~80% of transactions -- back-to-back traffic is what
    // actually stresses a FIFO -- with the remainder spread over the range.
    parameter int MIN_CYCLES_BETWEEN_TESTS = 1,
    parameter int MAX_CYCLES_BETWEEN_TESTS = 10,

    parameter int MAX_ERRORS = 25
);

    localparam int COUNT_WIDTH = $clog2(DEPTH + 1);
    localparam int ADDR_WIDTH = $clog2(DEPTH);
    localparam int READ_LATENCY = 2;  // ticks from accepted read to rd_data (F13)

    // Explicit boundary values for cp_occupancy. Written as clamped localparams
    // rather than inline ranges so the bins stay legal at the THRESHOLD == DEPTH
    // and THRESHOLD == 1 extremes (F10) instead of collapsing to empty ranges.
    localparam int AF_BELOW = (ALMOST_FULL_THRESHOLD > 0) ? ALMOST_FULL_THRESHOLD - 1 : 0;
    localparam int AF_ABOVE = (ALMOST_FULL_THRESHOLD < DEPTH) ? ALMOST_FULL_THRESHOLD + 1 : DEPTH;

    logic clk = 1'b0, rst, full, almost_full, wr_en, empty, rd_en;
    logic [COUNT_WIDTH-1:0] count;
    logic [WIDTH-1:0] wr_data, rd_data;

    int passed, failed;
    int accepted_writes, accepted_reads, data_checks;

    fifo_almost_full_2cycle_read #(
        .WIDTH                (WIDTH),
        .DEPTH                (DEPTH),
        .ALMOST_FULL_THRESHOLD(ALMOST_FULL_THRESHOLD)
    ) DUT (
        .clk        (clk),
        .rst        (rst),
        .full       (full),
        .almost_full(almost_full),
        .count      (count),
        .wr_en      (wr_en),
        .wr_data    (wr_data),
        .empty      (empty),
        .rd_en      (rd_en),
        .rd_data    (rd_data)
    );

    // One cycle of stimulus: what to request, what to write, and how long to
    // idle afterwards.
    class fifo_item;
        rand bit             wr_en;
        rand bit             rd_en;
        rand bit [WIDTH-1:0] wr_data;
        rand int unsigned    idle_cycles;

        constraint c_idle {
            idle_cycles inside {[MIN_CYCLES_BETWEEN_TESTS - 1 : MAX_CYCLES_BETWEEN_TESTS - 1]};
        }
    endclass

    // Parameterized rather than the generic `mailbox` bit_diff uses: the two
    // scoreboard mailboxes carry the same payload type and swapping them would
    // otherwise be a silent runtime bug rather than an elaboration error.
    mailbox #(fifo_item) driver_mailbox = new;
    mailbox #(logic [WIDTH-1:0]) scoreboard_expected_mailbox = new;
    mailbox #(logic [WIDTH-1:0]) scoreboard_actual_mailbox = new;

    // -----------------------------------------------------------------------
    // Bookkeeping helpers
    // -----------------------------------------------------------------------
    string test_names[$];
    string test_specs[$];
    int    test_fails[$];
    int    fails_at_test_start;

    function automatic void fail(input string msg);
        failed++;
        $display("[%0t] FAIL: %s", $realtime, msg);
        if (failed >= MAX_ERRORS)
            $fatal(1, "Aborting: %0d failures (MAX_ERRORS).", failed);
    endfunction

    task automatic begin_test(input string tname, input string specs);
        test_names.push_back(tname);
        test_specs.push_back(specs);
        fails_at_test_start = failed;
        if (LOG_TESTS) $display("[%0t] ---- %s  (%s)", $realtime, tname, specs);
    endtask

    task automatic end_test();
        test_fails.push_back(failed - fails_at_test_start);
    endtask

    // -----------------------------------------------------------------------
    // Reference model (docs/verification_plan.md Sec.2)
    //
    // A queue mirroring the stored entries plus a 2-deep pipeline that mirrors
    // the DUT's RAM-output register + output register, so the expected rd_data
    // is published on the same tick the DUT's rd_data holds it -- not one tick
    // early. That timing is the whole point: a scoreboard that only checks
    // rd_data *ordering* passes even when the latency is wrong.
    //
    // The model is also where the every-cycle flag comparison lives (F1-F12).
    // Doing it here rather than in a separate process keeps it race-free: the
    // DUT's pre-edge flags are compared against the model state as of the
    // previous edge, before this edge's model update is applied.
    // -----------------------------------------------------------------------
    logic [WIDTH-1:0] model_q[$];
    int model_wr_idx, model_rd_idx;
    int model_wr_wraps, model_rd_wraps;  // F9 visibility, sampled by cp_wraps

    function automatic void check_flags();
        automatic int unsigned occ = model_q.size();
        automatic bit exp_full = (occ == DEPTH);
        automatic bit exp_empty = (occ == 0);
        automatic bit exp_af = AF_MODEL_USES_GTE ? (occ >= ALMOST_FULL_THRESHOLD)
                                                 : (occ == ALMOST_FULL_THRESHOLD);

        // F2/F3/F4/F5/F6/F7/F8/F9: occupancy accounting under every interleaving.
        // Compared as 4-state vectors, not cast to int, so an X on count fails
        // here instead of silently converting to 0.
        if (count !== COUNT_WIDTH'(occ)) fail($sformatf("count = %0d, expected %0d", count, occ));
        else passed++;

        // F4/F11
        if (full !== exp_full) fail($sformatf("full = %0b, expected %0b (count=%0d)", full, exp_full, occ));
        else passed++;

        // F5/F12
        if (empty !== exp_empty) fail($sformatf("empty = %0b, expected %0b (count=%0d)", empty, exp_empty, occ));
        else passed++;

        // F10 -- see the spec/RTL discrepancy note in the file header.
        if (almost_full !== exp_af)
            fail($sformatf("almost_full = %0b, expected %0b (count=%0d, THRESHOLD=%0d)",
                           almost_full, exp_af, occ, ALMOST_FULL_THRESHOLD));
        else passed++;

        // F2/F3/F9: pointers increment on committed accesses and wrap mod DEPTH.
        if (CHECK_INTERNAL_PTRS) begin
            if (DUT.wr_addr_r !== ADDR_WIDTH'(model_wr_idx))
                fail($sformatf("wr_addr_r = %0d, expected %0d", DUT.wr_addr_r, model_wr_idx));
            else passed++;

            if (DUT.rd_addr_r !== ADDR_WIDTH'(model_rd_idx))
                fail($sformatf("rd_addr_r = %0d, expected %0d", DUT.rd_addr_r, model_rd_idx));
            else passed++;
        end
    endfunction

    initial begin : reference_model
        static bit exp_v1 = 1'b0, exp_v2 = 1'b0;
        static logic [WIDTH-1:0] exp_d1, exp_d2;
        static bit acc_wr, acc_rd;

        forever begin
            @(posedge clk);

            if (rst) begin
                // F1/F15: pointers and count clear regardless of prior occupancy.
                model_q.delete();
                model_wr_idx = 0;
                model_rd_idx = 0;
                exp_v1 = 1'b0;
                exp_v2 = 1'b0;
                // The read pipeline is deliberately NOT reset in the RTL
                // (fifo_spec.md Sec.3), so anything in flight would still land
                // correctly. The model drops it anyway -- under the consumer
                // contract that data is never sampled, so asserting on it would
                // be checking a guarantee the design does not make.
            end else begin
                check_flags();

                // A read accepted READ_LATENCY ticks ago matures now.
                if (exp_v2) scoreboard_expected_mailbox.put(exp_d2);
                exp_v2 = exp_v1;
                exp_d2 = exp_d1;

                // Acceptance is unconditional in both directions: a read at
                // empty is dropped whether or not a write commits (F5/F8), and
                // a write at full is dropped whether or not a read commits
                // (F4/F7). Neither qualifier depends on the other.
                //
                // These two lines look identical to the RTL's valid_rd/valid_wr
                // and must NOT be maintained by copying them from it -- they
                // encode the spec rule, which happens to agree. A model that
                // inherits its acceptance rule from the implementation cannot
                // detect a bug in that rule; see verification_plan.md Sec.4,
                // where exactly that hid an F7 mismatch from every per-cycle
                // check in this file.
                acc_rd = rd_en && !empty;  // F3/F5/F8
                acc_wr = wr_en && !full;   // F2/F4/F7

                // Both decisions are made from the flags sampled above, before
                // the queue is touched, so the pop/push order below does not
                // affect the result. That ordering-independence is what makes
                // F6/F7/F8 fall out of the same two lines rather than needing
                // three special cases.
                exp_v1 = 1'b0;
                if (acc_rd) begin
                    exp_v1 = 1'b1;
                    exp_d1 = model_q.pop_front();  // F14: strict FIFO order
                    model_rd_idx = (model_rd_idx + 1) % DEPTH;
                    if (model_rd_idx == 0) model_rd_wraps++;  // F9
                    accepted_reads++;
                end
                if (acc_wr) begin
                    model_q.push_back(wr_data);
                    model_wr_idx = (model_wr_idx + 1) % DEPTH;
                    if (model_wr_idx == 0) model_wr_wraps++;  // F9
                    accepted_writes++;
                end
            end
        end
    end

    // -----------------------------------------------------------------------
    // Clock
    // -----------------------------------------------------------------------
    initial begin : generate_clock
        forever #5 clk <= ~clk;
    end

    initial begin : initialization
        $timeformat(-9, 0, " ns");

        if (DEPTH < 2) $fatal(1, "DEPTH must be >= 2 (cx_wr_rd_full_empty assumes full and empty are mutually exclusive).");
        if (2 ** $clog2(DEPTH) != DEPTH) $fatal(1, "DEPTH must be a power of 2 (fifo_spec.md Sec.1).");
        if (ALMOST_FULL_THRESHOLD < 1 || ALMOST_FULL_THRESHOLD > DEPTH)
            $fatal(1, "ALMOST_FULL_THRESHOLD must be in [1, DEPTH].");

        $display("[%0t] fifo_almost_full_2cycle_read_tb: WIDTH=%0d DEPTH=%0d ALMOST_FULL_THRESHOLD=%0d",
                 $realtime, WIDTH, DEPTH, ALMOST_FULL_THRESHOLD);
        $display("[%0t] random seed = %0d  (rerun with -sv_seed <n> to reproduce)",
                 $realtime, $get_initial_random_seed());
        if (ALMOST_FULL_THRESHOLD == DEPTH)
            $display("[%0t] NOTE: ALMOST_FULL_THRESHOLD == DEPTH, so almost_full coincides with full. Elaborate a second instance with THRESHOLD < DEPTH to close the cp_af_vs_full af_only bin (verification_plan.md Sec.4).",
                     $realtime);
    end

    // -----------------------------------------------------------------------
    // Generator -- random stress stimulus (F11, F12, F14).
    //
    // Weights sweep across the run: write-heavy first so the FIFO sits at full
    // under sustained back-pressure, read-heavy last so it sits at empty. A
    // single balanced distribution spends almost all its time mid-occupancy and
    // closes neither extreme reliably.
    // -----------------------------------------------------------------------
    initial begin : generator
        fifo_item test;
        int wr_weight, rd_weight;

        for (int i = 0; i < NUM_TESTS; i++) begin
            if (i < NUM_TESTS / 3) begin
                wr_weight = 85;
                rd_weight = 30;  // drive toward full  -> F11
            end else if (i < (2 * NUM_TESTS) / 3) begin
                wr_weight = 55;
                rd_weight = 55;  // balanced           -> F6/F9/F14
            end else begin
                wr_weight = 25;
                rd_weight = 85;  // drive toward empty -> F12
            end

            test = new();
            assert (test.randomize() with {
                wr_en dist {1'b1 :/ wr_weight, 1'b0 :/ 100 - wr_weight};
                rd_en dist {1'b1 :/ rd_weight, 1'b0 :/ 100 - rd_weight};
                idle_cycles dist {
                    0 :/ 80,
                    [MIN_CYCLES_BETWEEN_TESTS - 1 : MAX_CYCLES_BETWEEN_TESTS - 1] :/ 20
                };
            })
            else $fatal(1, "Failed to randomize.");

            driver_mailbox.put(test);
        end
    end

    // -----------------------------------------------------------------------
    // Driver -- directed phases first (one per verification_plan.md Sec.2 item),
    // then the randomized stress loop off driver_mailbox.
    // -----------------------------------------------------------------------
    logic [WIDTH-1:0] stim_data = '0;

    function automatic logic [WIDTH-1:0] next_data();
        stim_data = stim_data + 1'b1;
        return stim_data;
    endfunction

    task automatic apply_reset(input int unsigned cycles = 5);
        rst     <= 1'b1;
        wr_en   <= 1'b0;
        rd_en   <= 1'b0;
        wr_data <= '0;
        repeat (cycles) @(posedge clk);
        @(negedge clk);
        rst <= 1'b0;
        @(posedge clk);  // first edge at which the DUT sees rst deasserted
    endtask

    task automatic drive_cycle(input bit w, input bit r, input logic [WIDTH-1:0] d = '0);
        wr_en   <= w;
        rd_en   <= r;
        // F2: wr_data must be ignored unless wr_en && !full. Feeding garbage on
        // idle cycles means a DUT that latched unqualified data would corrupt
        // the stream and get caught by the scoreboard.
        wr_data <= (w || !TOGGLE_INPUTS_WHILE_IDLE) ? d : WIDTH'($urandom);
        @(posedge clk);
    endtask

    task automatic idle(input int unsigned n = 1);
        repeat (n) drive_cycle(1'b0, 1'b0);
    endtask

    // Checks the DUT's post-edge state. Sampled at a negedge so there is no
    // race with the NBA updates from the edge that produced it.
    task automatic expect_state(input string tname, input int unsigned exp_count);
        automatic bit exp_full = (exp_count == DEPTH);
        automatic bit exp_empty = (exp_count == 0);
        automatic bit exp_af = AF_MODEL_USES_GTE ? (exp_count >= ALMOST_FULL_THRESHOLD)
                                                 : (exp_count == ALMOST_FULL_THRESHOLD);
        @(negedge clk);
        if (count !== COUNT_WIDTH'(exp_count)) fail($sformatf("%s: count=%0d, expected %0d", tname, count, exp_count));
        else passed++;
        if (full !== exp_full) fail($sformatf("%s: full=%0b, expected %0b", tname, full, exp_full));
        else passed++;
        if (empty !== exp_empty) fail($sformatf("%s: empty=%0b, expected %0b", tname, empty, exp_empty));
        else passed++;
        if (almost_full !== exp_af) fail($sformatf("%s: almost_full=%0b, expected %0b", tname, almost_full, exp_af));
        else passed++;
    endtask

    task automatic fill(input int unsigned n);
        for (int i = 0; i < n; i++) drive_cycle(1'b1, 1'b0, next_data());
        wr_en <= 1'b0;
    endtask

    task automatic drain(input int unsigned n);
        for (int i = 0; i < n; i++) drive_cycle(1'b0, 1'b1);
        rd_en <= 1'b0;
    endtask

    // --- F1 -----------------------------------------------------------------
    task automatic test_reset();
        begin_test("test_reset", "F1");
        // Put something in first so the reset has state to clear rather than
        // passing trivially from a cold start.
        apply_reset();
        fill(DEPTH / 2);
        apply_reset();
        expect_state("test_reset", 0);
        if (CHECK_INTERNAL_PTRS) begin
            if (DUT.wr_addr_r !== '0) fail("test_reset: wr_addr_r not cleared");
            else passed++;
            if (DUT.rd_addr_r !== '0) fail("test_reset: rd_addr_r not cleared");
            else passed++;
        end
        // Deliberately no rd_data check: fifo_spec.md Sec.3 excludes the entire
        // read pipeline from reset, so `rd_data == 0` would assert a guarantee
        // the design does not make.
        end_test();
    endtask

    // --- F2, F4, F10 --------------------------------------------------------
    task automatic test_fill_to_full();
        begin_test("test_fill_to_full", "F2, F4, F10");
        apply_reset();
        // Step across the almost_full boundary one entry at a time so the
        // exact assert point is checked, not just "somewhere near it" (F10).
        for (int i = 1; i <= DEPTH; i++) begin
            drive_cycle(1'b1, 1'b0, next_data());
            wr_en <= 1'b0;
            expect_state($sformatf("test_fill_to_full (occupancy %0d)", i), i);
            wr_en <= 1'b1;
        end
        wr_en <= 1'b0;
        // F4: writes while full are dropped and do not advance wr_addr_r.
        for (int i = 0; i < 4; i++) drive_cycle(1'b1, 1'b0, next_data());
        wr_en <= 1'b0;
        expect_state("test_fill_to_full (overflow dropped)", DEPTH);
        end_test();
    endtask

    // --- F3, F5, F10 --------------------------------------------------------
    task automatic test_drain_to_empty();
        begin_test("test_drain_to_empty", "F3, F5, F10");
        apply_reset();
        fill(DEPTH);
        for (int i = DEPTH - 1; i >= 0; i--) begin
            drive_cycle(1'b0, 1'b1);
            rd_en <= 1'b0;
            expect_state($sformatf("test_drain_to_empty (occupancy %0d)", i), i);
            rd_en <= 1'b1;
        end
        rd_en <= 1'b0;
        // F5: reads while empty are dropped and do not advance rd_addr_r.
        for (int i = 0; i < 4; i++) drive_cycle(1'b0, 1'b1);
        rd_en <= 1'b0;
        expect_state("test_drain_to_empty (underflow dropped)", 0);
        end_test();
    endtask

    // --- F9 -----------------------------------------------------------------
    task automatic test_pointer_wrap();
        automatic int wr_wraps_before, rd_wraps_before;
        begin_test("test_pointer_wrap", "F9");
        apply_reset();
        wr_wraps_before = model_wr_wraps;
        rd_wraps_before = model_rd_wraps;
        // Keep occupancy mid-range while pushing >= 2*DEPTH entries through, so
        // both pointers wrap at least twice independently of each other.
        fill(DEPTH / 2);
        for (int i = 0; i < 3 * DEPTH; i++) drive_cycle(1'b1, 1'b1, next_data());
        wr_en <= 1'b0;
        rd_en <= 1'b0;
        drain(DEPTH / 2);
        expect_state("test_pointer_wrap", 0);
        if (model_wr_wraps - wr_wraps_before < 2)
            fail($sformatf("test_pointer_wrap: only %0d write wraps, need >= 2", model_wr_wraps - wr_wraps_before));
        else passed++;
        if (model_rd_wraps - rd_wraps_before < 2)
            fail($sformatf("test_pointer_wrap: only %0d read wraps, need >= 2", model_rd_wraps - rd_wraps_before));
        else passed++;
        end_test();
    endtask

    // --- F6 -----------------------------------------------------------------
    // Kept separate from _at_full / _at_empty on purpose: the three cases take
    // different paths through valid_wr/valid_rd, and collapsing them into one
    // "simultaneous r/w" test loses exactly the corner they exist to cover.
    task automatic test_simultaneous_rw_mid();
        begin_test("test_simultaneous_rw_mid", "F6");
        apply_reset();
        fill(DEPTH / 2);
        for (int i = 0; i < DEPTH; i++) begin
            drive_cycle(1'b1, 1'b1, next_data());
            wr_en <= 1'b0;
            rd_en <= 1'b0;
            // Both commit, count unchanged, both pointers advance.
            expect_state("test_simultaneous_rw_mid", DEPTH / 2);
            wr_en <= 1'b1;
            rd_en <= 1'b1;
        end
        wr_en <= 1'b0;
        rd_en <= 1'b0;
        drain(DEPTH / 2);
        end_test();
    endtask

    // --- F7 -----------------------------------------------------------------
    task automatic test_simultaneous_rw_at_full();
        begin_test("test_simultaneous_rw_at_full", "F7");
        apply_reset();
        fill(DEPTH);
        expect_state("test_simultaneous_rw_at_full (setup)", DEPTH);

        // First simultaneous access while full: the read commits, the write is
        // dropped. valid_wr is qualified by !full unconditionally, so the slot
        // the read frees is not available to the write until the next cycle.
        drive_cycle(1'b1, 1'b1, next_data());
        wr_en <= 1'b0;
        rd_en <= 1'b0;
        expect_state("test_simultaneous_rw_at_full (write dropped at full)", DEPTH - 1);

        // From here the FIFO is no longer full, so both accesses commit every
        // cycle and occupancy holds at DEPTH-1. One slot of effective depth is
        // the entire cost of the F7 rule; throughput is unaffected.
        for (int i = 0; i < DEPTH; i++) begin
            drive_cycle(1'b1, 1'b1, next_data());
            wr_en <= 1'b0;
            rd_en <= 1'b0;
            expect_state("test_simultaneous_rw_at_full (steady state)", DEPTH - 1);
        end

        drain(DEPTH - 1);  // ordering of the swapped-through data is checked by the scoreboard (F14)
        end_test();
    endtask

    // --- F8 -----------------------------------------------------------------
    task automatic test_simultaneous_rw_at_empty();
        begin_test("test_simultaneous_rw_at_empty", "F8");
        apply_reset();
        expect_state("test_simultaneous_rw_at_empty (setup)", 0);
        // Write commits, read is dropped (nothing valid to dequeue): count -> 1.
        drive_cycle(1'b1, 1'b1, next_data());
        wr_en <= 1'b0;
        rd_en <= 1'b0;
        expect_state("test_simultaneous_rw_at_empty", 1);
        // Repeat from empty a few times to confirm it is not a one-shot.
        drain(1);
        expect_state("test_simultaneous_rw_at_empty (re-emptied)", 0);
        for (int i = 0; i < 4; i++) begin
            drive_cycle(1'b1, 1'b1, next_data());
            wr_en <= 1'b0;
            rd_en <= 1'b0;
            expect_state("test_simultaneous_rw_at_empty (repeat)", 1);
            drain(1);
        end
        end_test();
    endtask

    // --- F4, F11 ------------------------------------------------------------
    task automatic test_write_while_full_no_read();
        begin_test("test_write_while_full_no_read", "F4, F11");
        apply_reset();
        // Fill with a known, checkable pattern.
        fill(DEPTH);
        expect_state("test_write_while_full_no_read (setup)", DEPTH);
        // Sustained back-pressure, not a single cycle -- that's what F11 adds
        // over F4.
        for (int i = 0; i < 4 * DEPTH; i++) drive_cycle(1'b1, 1'b0, next_data());
        wr_en <= 1'b0;
        expect_state("test_write_while_full_no_read (held at full)", DEPTH);
        // Draining now proves the stored data survived untouched: the scoreboard
        // compares every dequeued word against the model queue (F11/F14).
        drain(DEPTH);
        expect_state("test_write_while_full_no_read (drained)", 0);
        end_test();
    endtask

    // --- F5, F12 ------------------------------------------------------------
    task automatic test_read_while_empty_no_write();
        automatic logic [WIDTH-1:0] held;
        begin_test("test_read_while_empty_no_write", "F5, F12");
        apply_reset();
        // Push one word through first so rd_data holds a known value; an empty
        // read must not disturb it.
        fill(1);
        drain(1);
        idle(READ_LATENCY + 1);  // let the read mature onto rd_data
        expect_state("test_read_while_empty_no_write (setup)", 0);
        held = rd_data;
        for (int i = 0; i < 4 * DEPTH; i++) begin
            drive_cycle(1'b0, 1'b1);
            // F12: rd_data returns nothing distinct from its held value.
            if (rd_data !== held)
                fail($sformatf("test_read_while_empty_no_write: rd_data %0h -> %0h on an empty read", held, rd_data));
            else passed++;
        end
        rd_en <= 1'b0;
        expect_state("test_read_while_empty_no_write (held at empty)", 0);
        end_test();
    endtask

    // --- F15 ----------------------------------------------------------------
    task automatic test_reset_mid_burst();
        begin_test("test_reset_mid_burst", "F15");
        // Nonzero occupancy AND data in flight in the read pipeline when reset
        // lands -- the case the cocotb reset test only reaches at rest.
        for (int occ = 1; occ <= 3; occ++) begin
            apply_reset();
            fill(DEPTH / 2);
            drive_cycle(1'b0, 1'b1);  // accepted read, now in flight
            if (occ > 1) drive_cycle(1'b1, 1'b1, next_data());  // second read in flight behind it
            rst <= 1'b1;
            wr_en <= 1'b0;
            rd_en <= 1'b0;
            repeat (occ) @(posedge clk);
            @(negedge clk);
            rst <= 1'b0;
            @(posedge clk);
            expect_state($sformatf("test_reset_mid_burst (variant %0d)", occ), 0);
            if (CHECK_INTERNAL_PTRS) begin
                if (DUT.wr_addr_r !== '0 || DUT.rd_addr_r !== '0)
                    fail($sformatf("test_reset_mid_burst (variant %0d): pointers not cleared", occ));
                else passed++;
            end
            // Whatever was in flight in rd_data_ram/rd_data is left as-is by
            // design (fifo_spec.md Sec.3 / F15) and is intentionally unchecked.
            // The FIFO must still be usable immediately afterwards:
            fill(2);
            drain(2);
            idle(READ_LATENCY + 1);
            expect_state($sformatf("test_reset_mid_burst (reusable, variant %0d)", occ), 0);
        end
        end_test();
    endtask

    // --- F13 ----------------------------------------------------------------
    task automatic test_back_to_back_reads();
        automatic int prev;
        begin_test("test_back_to_back_reads", "F13");
        apply_reset();
        fill(DEPTH);
        @(negedge clk);
        prev = int'(count);
        // rd_en held every cycle: exactly one read must be accepted per cycle,
        // i.e. the extra pipeline stage costs latency but not throughput.
        for (int i = 0; i < DEPTH; i++) begin
            rd_en <= 1'b1;
            @(negedge clk);
            if (int'(count) != prev - 1)
                fail($sformatf("test_back_to_back_reads: read %0d left count=%0d, expected %0d (throughput loss)",
                               i, count, prev - 1));
            else passed++;
            prev = int'(count);
        end
        rd_en <= 1'b0;
        // Each of those DEPTH reads is separately checked by rd_monitor +
        // scoreboard for arriving exactly READ_LATENCY ticks after acceptance,
        // in order, with no dropped or duplicated words.
        expect_state("test_back_to_back_reads (drained)", 0);
        end_test();
    endtask

    // --- F16 ----------------------------------------------------------------
    task automatic test_read_pipeline_bubble();
        automatic logic [WIDTH-1:0] held;
        begin_test("test_read_pipeline_bubble", "F16");
        apply_reset();
        fill(4);

        // Case 1: an accepted read followed by a long gap with rd_en low.
        drive_cycle(1'b0, 1'b1);
        idle(READ_LATENCY);  // the accepted read's data lands on rd_data here
        @(negedge clk);
        held = rd_data;
        repeat (2 * READ_LATENCY + 2) begin
            @(negedge clk);
            if (rd_data !== held)
                fail($sformatf("test_read_pipeline_bubble: rd_data %0h -> %0h with no accepted read", held, rd_data));
            else passed++;
        end

        // Case 2: rd_en asserted but dropped because the FIFO is empty (F5/F8) --
        // the unmoved read address must not push a bubble down the pipeline.
        drain(3);
        idle(READ_LATENCY + 1);
        @(negedge clk);
        held = rd_data;
        for (int i = 0; i < 2 * DEPTH; i++) begin
            drive_cycle(1'b0, 1'b1);  // dropped, FIFO is empty
            if (rd_data !== held)
                fail($sformatf("test_read_pipeline_bubble: rd_data %0h -> %0h on a dropped read", held, rd_data));
            else passed++;
        end
        rd_en <= 1'b0;

        // Case 3: interleave accepted reads with idle cycles -- rd_data must
        // step exactly once per accepted read, never on the bubble cycles.
        fill(DEPTH);
        for (int i = 0; i < DEPTH / 2; i++) begin
            drive_cycle(1'b0, 1'b1);
            idle($urandom_range(1, 3));
        end
        rd_en <= 1'b0;
        drain(DEPTH - DEPTH / 2);
        end_test();
    endtask

    // --- F10 ----------------------------------------------------------------
    // ALMOST_FULL_THRESHOLD is elaboration-time, so a single instance cannot
    // sweep it (verification_plan.md Sec.4 calls for a second parallel
    // instance). What this test *can* do is walk occupancy across the
    // configured boundary in both directions, one entry at a time, so the exact
    // assert and deassert points are pinned rather than approximated.
    task automatic test_almost_full_threshold();
        begin_test("test_almost_full_threshold", "F10");
        apply_reset();
        for (int i = 1; i <= DEPTH; i++) begin
            drive_cycle(1'b1, 1'b0, next_data());
            wr_en <= 1'b0;
            expect_state($sformatf("test_almost_full_threshold (rising, occ=%0d)", i), i);
        end
        for (int i = DEPTH - 1; i >= 0; i--) begin
            drive_cycle(1'b0, 1'b1);
            rd_en <= 1'b0;
            expect_state($sformatf("test_almost_full_threshold (falling, occ=%0d)", i), i);
        end
        end_test();
    endtask

    // --- F11, F12, F14 ------------------------------------------------------
    task automatic test_random_stress();
        fifo_item item;
        begin_test("test_random_stress", "F11, F12, F14");
        apply_reset();
        for (int i = 0; i < NUM_TESTS; i++) begin
            driver_mailbox.get(item);
            drive_cycle(item.wr_en, item.rd_en, item.wr_data);
            if (item.idle_cycles > 0) idle(item.idle_cycles);
        end
        wr_en <= 1'b0;
        rd_en <= 1'b0;
        // Drain whatever is left so the last words get checked for ordering.
        drain(DEPTH);
        idle(READ_LATENCY + 2);
        end_test();
    endtask

    initial begin : driver
        test_reset();
        test_fill_to_full();
        test_drain_to_empty();
        test_pointer_wrap();
        test_simultaneous_rw_mid();
        test_simultaneous_rw_at_full();
        test_simultaneous_rw_at_empty();
        test_write_while_full_no_read();
        test_read_while_empty_no_write();
        test_reset_mid_burst();
        test_back_to_back_reads();
        test_read_pipeline_bubble();
        test_almost_full_threshold();
        test_random_stress();

        idle(READ_LATENCY + 4);  // let the read pipeline flush before reporting
        report();
        disable generate_clock;
        $finish;
    end

    // -----------------------------------------------------------------------
    // Monitors
    // -----------------------------------------------------------------------

    // Observes committed writes (F2). Logging/visibility only -- the model
    // snoops the bus directly, since it has to see writes and reads resolved in
    // the same tick to get F7/F8 right.
    initial begin : wr_monitor
        forever begin
            @(posedge clk iff (!rst && wr_en && !full));
            if (LOG_WR_MONITOR)
                $display("[%0t] wr_monitor: accepted write data=%0h (count=%0d)", $realtime, wr_data, count);
        end
    end

    // Samples rd_data exactly READ_LATENCY ticks after each accepted read
    // (F13). The two-stage shift register is what makes this work under
    // back-to-back reads -- a blocking "wait 2 cycles then sample" would miss
    // every read but the first.
    initial begin : rd_monitor
        static bit acc_d1 = 1'b0, acc_d2 = 1'b0;

        forever begin
            @(posedge clk);
            if (rst) begin
                acc_d1 = 1'b0;
                acc_d2 = 1'b0;
            end else begin
                if (acc_d2) begin
                    scoreboard_actual_mailbox.put(rd_data);
                    if (LOG_RD_MONITOR)
                        $display("[%0t] rd_monitor: rd_data=%0h matured", $realtime, rd_data);
                end
                acc_d2 = acc_d1;
                acc_d1 = rd_en && !empty;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Scoreboard -- data integrity and ordering (F14), and by construction the
    // 2-cycle latency (F13): expected and actual are published on the same tick
    // by two processes that independently derive it, so a latency change breaks
    // the value comparison rather than silently passing.
    // -----------------------------------------------------------------------
    initial begin : scoreboard
        logic [WIDTH-1:0] expected, actual;

        forever begin
            scoreboard_expected_mailbox.get(expected);
            scoreboard_actual_mailbox.get(actual);
            data_checks++;
            if (actual === expected) passed++;
            else fail($sformatf("rd_data = %0h, expected %0h (check #%0d)", actual, expected, data_checks));
        end
    end

    // -----------------------------------------------------------------------
    // Functional coverage (verification_plan.md Sec.3 "Covergroups")
    // -----------------------------------------------------------------------
    covergroup cg_fifo @(posedge clk);
        option.per_instance = 1;
        option.name = "cg_fifo";

        // F2/F3/F9/F10 -- occupancy, with explicit bins at the threshold
        // boundary rather than a range that only lands "near" it.
        cp_occupancy: coverpoint count iff (!rst) {
            bins zero = {0};
            bins mid[8] = {[1 : DEPTH - 1]};
            bins at_full = {DEPTH};
            bins below_threshold = {AF_BELOW};
            bins at_threshold = {ALMOST_FULL_THRESHOLD};
            bins above_threshold = {AF_ABOVE};
        }

        cp_wr: coverpoint wr_en iff (!rst) {
            bins no = {1'b0};
            bins yes = {1'b1};
        }
        cp_rd: coverpoint rd_en iff (!rst) {
            bins no = {1'b0};
            bins yes = {1'b1};
        }
        cp_full: coverpoint full iff (!rst) {
            bins no = {1'b0};
            bins yes = {1'b1};
        }
        cp_empty: coverpoint empty iff (!rst) {
            bins no = {1'b0};
            bins yes = {1'b1};
        }

        // F4-F8, F11, F12. `full && empty` cannot occur for DEPTH > 1 (count
        // cannot be both 0 and DEPTH), so it is an illegal_bin rather than a
        // silent ignore_bin: the exclusion is documented AND checked, which is
        // what makes it defensible to whoever reviews the UCDB later.
        cx_wr_rd_full_empty: cross cp_wr, cp_rd, cp_full, cp_empty {
            illegal_bins full_and_empty = binsof (cp_full.yes) && binsof (cp_empty.yes);
        }

        // F9 -- occupancy at the extremes, crossed with how many times the read
        // pointer has wrapped. Restricted to the extreme occupancy bins so the
        // cross stays closable instead of exploding into a matrix nobody hits.
        cp_wraps: coverpoint model_rd_wraps iff (!rst) {
            bins none = {0};
            bins one = {1};
            bins two_plus = {[2 : $]};
        }
        cx_occupancy_wrap: cross cp_occupancy, cp_wraps {
            ignore_bins non_extremes =
                !binsof (cp_occupancy.zero) && !binsof (cp_occupancy.at_full);
        }

        // F10 -- makes the "almost_full coincides with full" case explicit
        // rather than inferring it. almost_full is an exact-match flag
        // (count == THRESHOLD), so at the ALMOST_FULL_THRESHOLD == DEPTH
        // default only `neither` and `af_and_full` are reachable. `af_only`
        // (occupancy sitting exactly on a sub-DEPTH threshold) and `full_only`
        // (occupancy above that threshold, so the flag has dropped again) close
        // from a second elaboration with THRESHOLD < DEPTH, per
        // verification_plan.md Sec.4.
        cp_af_vs_full: coverpoint {almost_full, full} iff (!rst) {
            bins neither = {2'b00};
            bins af_only = {2'b10};
            bins af_and_full = {2'b11};
            bins full_only = {2'b01};
        }
    endgroup

    cg_fifo cg_fifo_inst = new();

    // -----------------------------------------------------------------------
    // SVA (verification_plan.md Sec.3 "SVA"). `wr_ptr`/`rd_ptr` in the plan are
    // `wr_addr_r`/`rd_addr_r` in the RTL. Note the active-high, synchronous
    // `rst` -- polarity flipped from the earlier `rst_n` revisions.
    // -----------------------------------------------------------------------

    // F4/F11: a write attempted while full with no simultaneous read does not
    // advance the write pointer and cannot push count past DEPTH. (That the
    // stored *data* is intact is checked by the scoreboard, which reads it all
    // back out -- $stable does not work on an unpacked array.)
    property p_no_overflow;
        @(posedge clk) disable iff (rst)
        (full && wr_en && !rd_en) |=> (count == COUNT_WIDTH'(DEPTH) && $stable(DUT.wr_addr_r));
    endproperty
    a_no_overflow : assert property (p_no_overflow)
        else $error("a_no_overflow: count=%0d wr_addr_r=%0d after a write attempted while full", count, DUT.wr_addr_r);
    c_no_overflow : cover property (@(posedge clk) disable iff (rst) (full && wr_en && !rd_en));

    // F5/F12: a read attempted while empty with no simultaneous write does not
    // advance the read pointer and cannot push count below 0.
    property p_no_underflow;
        @(posedge clk) disable iff (rst)
        (empty && rd_en && !wr_en) |=> (count == 0 && $stable(DUT.rd_addr_r));
    endproperty
    a_no_underflow : assert property (p_no_underflow)
        else $error("a_no_underflow: count=%0d rd_addr_r=%0d after a read attempted while empty", count, DUT.rd_addr_r);
    c_no_underflow : cover property (@(posedge clk) disable iff (rst) (empty && rd_en && !wr_en));

    // F1/F15: reset clears both pointers and count regardless of prior
    // occupancy or of what is in flight in the read pipeline. Asserts nothing
    // about rd_data/rd_data_ram -- fifo_spec.md Sec.3 excludes the read
    // pipeline from reset by design.
    property p_ptr_reset_stable;
        @(posedge clk) rst |=> (DUT.wr_addr_r == '0 && DUT.rd_addr_r == '0 && count == '0);
    endproperty
    a_ptr_reset_stable : assert property (p_ptr_reset_stable)
        else $error("a_ptr_reset_stable: wr_addr_r=%0d rd_addr_r=%0d count=%0d after reset",
                    DUT.wr_addr_r, DUT.rd_addr_r, count);
    c_reset_mid_burst : cover property (@(posedge clk) (!rst && count > 0) ##1 rst);

    // F13: the entry dequeued by an accepted read appears on rd_data exactly
    // two ticks later. The local variable captures the RAM word at the accept
    // tick, which is what makes this hold under back-to-back reads -- `##2`,
    // not `##1` and not `|->`.
    property p_read_latency;
        logic [WIDTH-1:0] expected;
        @(posedge clk) disable iff (rst)
        (rd_en && !empty, expected = DUT.ram[DUT.rd_addr_r]) |-> ##2 (rd_data == expected);
    endproperty
    a_read_latency : assert property (p_read_latency)
        else $error("a_read_latency: rd_data=%0h two cycles after an accepted read", rd_data);
    c_back_to_back_reads : cover property (
        @(posedge clk) disable iff (rst) (rd_en && !empty)[*4]);

    // F16: with no read accepted, the read address does not move, so rd_data_ram
    // re-reads the same word and rd_data cannot show a bubble two cycles later.
    //
    // Two guards, both load-bearing:
    //  - `!empty`: while empty, a write can land on the very address rd_addr_r
    //    points at, so rd_data legitimately changes with no accepted read.
    //    Inconsequential under the fifo_spec.md Sec.3 consumer contract, but it
    //    is not a bubble and must not be asserted against.
    //  - `!rst` on the next tick: rd_addr_r resets to 0, so reset can change
    //    what the pipeline picks up even with no accepted read (F15). Expected,
    //    not a bubble -- verification_plan.md Sec.3 calls this exclusion out
    //    explicitly.
    property p_read_pipeline_no_bubble;
        @(posedge clk) (!rst && !empty && !rd_en) ##1 !rst |-> ##2 $stable(rd_data);
    endproperty
    a_read_pipeline_no_bubble : assert property (p_read_pipeline_no_bubble)
        else $error("a_read_pipeline_no_bubble: rd_data changed to %0h with no accepted read", rd_data);
    c_read_bubble : cover property (
        @(posedge clk) disable iff (rst) (rd_en && !empty) ##1 (!rd_en)[*3]);

    // -----------------------------------------------------------------------
    // Final report -- the traceability matrix that goes into the coverage
    // report (verification_plan.md Sec.1).
    // -----------------------------------------------------------------------
    task automatic report();
        $display("");
        $display("=========================================================================");
        $display(" fifo_almost_full_2cycle_read_tb -- traceability");
        $display(" WIDTH=%0d DEPTH=%0d ALMOST_FULL_THRESHOLD=%0d seed=%0d",
                 WIDTH, DEPTH, ALMOST_FULL_THRESHOLD, $get_initial_random_seed());
        $display("-------------------------------------------------------------------------");
        $display(" %-34s %-18s %s", "TEST", "SPEC IDS", "RESULT");
        $display("-------------------------------------------------------------------------");
        foreach (test_names[i]) begin
            if (i >= test_fails.size())
                $display(" %-34s %-18s %s", test_names[i], test_specs[i], "INCOMPLETE");
            else if (test_fails[i] == 0)
                $display(" %-34s %-18s %s", test_names[i], test_specs[i], "PASS");
            else
                $display(" %-34s %-18s %s", test_names[i], test_specs[i],
                         $sformatf("FAIL (%0d checks)", test_fails[i]));
        end
        $display("-------------------------------------------------------------------------");
        $display(" accepted writes : %0d", accepted_writes);
        $display(" accepted reads  : %0d", accepted_reads);
        $display(" rd_data checks  : %0d (2-cycle latency, F13/F14)", data_checks);
        $display(" pointer wraps   : wr=%0d rd=%0d (F9 needs >= 2 each)", model_wr_wraps, model_rd_wraps);
        $display(" coverage        : %0.2f%% (cg_fifo)", cg_fifo_inst.get_inst_coverage());
        $display("-------------------------------------------------------------------------");
        $display(" Checks completed: %0d passed, %0d failed", passed, failed);
        $display(" %s", (failed == 0) ? "*** TEST PASSED ***" : "*** TEST FAILED ***");
        $display("=========================================================================");
    endtask

endmodule
