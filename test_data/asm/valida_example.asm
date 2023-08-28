// This is an example .pil file containing powdr asm
// that could be generated from the following valida program:
//
//   imm32 4(fp), 100
//   jal 0(fp), main, 4
// loop:
//   beq loop, 0(fp), 0(fp) // there is no unconditional jump... We shold probabyl add it to improve prover loop
// main:
//   beqi exit, 0(fp), 0
//   add 4(fp), 0(fp), 0(fp)
//   subi 0(fp), 0(fp), 1
//   beq main, 0(fp), 0(fp)
// exit:
//   jalv 4(fp), 0(fp), 0
//
//
// The purpose is to check if it is easily possible to generate
// a compiler from valida assembly to powdr.


machine Main {

  constraints {
    macro is_binary(X) { X * (1 - X) = 0; };
    macro mutually_exclusive(X, Y) { X * Y = 0; };

    col witness addr;
    col witness step;
    col witness value;
    col witness is_load1;
    col witness is_load2;
    col witness is_write;

    // TODO we probably have to re-design the memory machine:
    // It is not unlikely that we do at least two if not three
    // memory operations on every instruction.
    // If we take one row per operation, the table will be exhausted
    // too quickly. Instead, we need to put all three operations in
    // one row.

    // columns are sorted by addr, then by step and then in the order
    // load1, load2, write.

    col witness address_change;
    col witness step_change;

    col witness op;
    op = is_load1 + is_load2 * 2 + is_write * 3;

    is_binary(is_load1);
    is_binary(is_load2);
    is_binary(is_write);
    mutually_exclusive(is_load1, is_load2);
    mutually_exclusive(is_load1, is_write);
    mutually_exclusive(is_load2, is_write);

    col fixed POSITIVE(i) { i + 1 };
    col fixed FIRST = [1] + [0]*;
    col fixed LAST(i) { FIRST(i + 1) };

    // if address_change is zero, then addr stays the same.
    (1 - address_change) * (addr' - addr) = 0;
    // if address_change is one, then addr increases (except on the last row)
    ((1 - LAST) * address_change) { addr' - addr } in { POSITIVE };

    (1 - step_change) * (step' - step) = 0;
    ((1 - LAST) * step_change) { step' - step } in { POSITIVE };

    // If the step does not change, the operation has to increase.
    (1 - step_change) { op' - op } in { POSITIVE };

    // If the next line is not a write and we stay at the same address, then the
    // value cannot change.
    (1 - is_write') * (1 - address_change) * (value' - value) = 0;

    // If the next line is not a write and we have an address change,
    // then the value is zero.
    (1 - is_write') * address_change * value' = 0;
  }


  constraints {

    macro memory_write(address, value) {
        { address, STEP, value }
        is
        Memory.is_write { Memory.addr, Memory.step, Memory.value };
    };

    macro memory_load_to_tmp1(address) {
        { address, STEP, tmp1 }
        is
        Memory.is_load1 { Memory.addr, Memory.step, Memory.value };
    };

    macro memory_load_to_tmp2(address) {
        { address, STEP, tmp2 }
        is
        Memory.is_load2 { Memory.addr, Memory.step, Memory.value };
    };

    macro branch_if(condition, target) {
        pc' = condition * target + (1 - condition) * (pc + 1);
    };

    macro is_u32(x) {
        x = b1 + b2 * 0x100 + b3 * 0x10000 + b4 * 0x1000000;
    };

    col fixed STEP(i) { i };
    col fixed FIRST = [1] + [0]*;

    col witness tmp1;
    col witness tmp2;
    //col witness tmp3;
    col witness tmp3_inv;
    col witness tmp3_is_zero;

    tmp3_is_zero = 1 - tmp3 * tmp3_inv;
    tmp3_is_zero * tmp3 = 0;
    tmp3_is_zero * (1 - tmp3_is_zero) = 0;

    // TODO if tmp3 is not used, we cannot set this stuff to zero.
    // so this means, if tmp3 is unused, it should be forced to a value somehow.

    col witness b1;
    col witness b2;
    col witness b3;
    col witness b4;
    col fixed BYTE(i) { i & 0xff };
    { b1 } in { BYTE };
    { b2 } in { BYTE };
    { b3 } in { BYTE };
    { b4 } in { BYTE };
    col witness sign_bit;
    sign_bit * (1 - sign_bit) = 0;
  }

        reg pc[@pc];
        reg fp;
        reg tmp3[<=];
        reg null;

        // This is not a valida instruction, but we use it to improve performance.
        instr jump target: label {
            pc' = target
        }

        instr imm32 fp_delta: signed, v: unsigned {
            memory_write(fp + fp_delta, v)
        }
        instr jal fp_delta: signed, target: label, shift: signed {
            memory_write(fp + fp_delta, pc + 1),
            pc' = target,
            fp' = fp + shift
        }
        instr jalv fp_delta: signed, target_delta: signed, shift: signed {
            memory_load_to_tmp1(fp + target_delta),
            memory_write(fp + fp_delta, pc + 1),
            pc' = tmp1,
            fp' = fp + shift
        }
        instr beq target: label, a: signed, b: signed -> tmp3 {
            memory_load_to_tmp1(fp + a),
            memory_load_to_tmp2(fp + b),
            tmp3 = tmp1 - tmp2,
            branch_if(tmp3_is_zero, target)
        }
        instr beqi target: label, fp_delta: signed, c: unsigned -> tmp3 {
            memory_load_to_tmp1(fp + fp_delta),
            tmp3 = tmp1 - c,
            branch_if(tmp3_is_zero, target)
        }
        instr add dest_delta: signed, a_delta: signed, b_delta: signed -> tmp3 {
            memory_load_to_tmp1(fp + a_delta),
            memory_load_to_tmp2(fp + b_delta),
            tmp3 = tmp1 + tmp2 - sign_bit * 2**32,
            is_u32(tmp3),
            memory_write(fp + dest_delta, tmp3)
        }
        instr subi dest_delta: signed, b_delta: signed, c: unsigned -> tmp3 {
            memory_load_to_tmp1(fp + b_delta),
            tmp3 + sign_bit * 2**32 = tmp1 + 2**32 - c,
            is_u32(tmp3),
            memory_write(fp + dest_delta, tmp3)
        }

  function main {
        // fp is zero in the beginning. We can use `jal` to set it to a higher value,
        // but jal will always write to memory as well.

        // This was "fp + 4", but it's always relative to fp, so we don't need it.
        imm32 4, 100;
        //jal 0, main, 4;
    loop::
        jump loop;
    main::
        null <=tmp3= beqi( exit, 0, 0);
        null <=tmp3= add (4, 0, 0);
        null <=tmp3= subi (0, 0, 1);
        null <=tmp3= beq (main, 0, 0);
    exit::
        jalv 4, 0, 0;
    }
}