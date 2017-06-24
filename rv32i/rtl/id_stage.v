`include "riscv_defs.v"

module id_stage
    #(
        parameter C_XLEN = 32
    )
    (
        // global
        input  wire                 clk_i,
        input  wire                 clk_en_i,
        input  wire                 resetb_i,
        // pfu interface
        input  wire                 pfu_dav_i,   // new fetch available
        output wire                 pfu_ack_o,   // ack this fetch
        input  wire  [`SOFID_RANGE] pfu_sofid_i, // first fetch since vectoring
        input  wire          [31:0] pfu_ins_i,   // instruction fetched
        input  wire                 pfu_ferr_i,  // this instruction fetch resulted in error
        input  wire          [31:0] pfu_pc_i,    // address of this instruction
        // ex stage interface
        output reg                  exs_valid_o,
        input  wire                 exs_stall_i,
        output reg   [`SOFID_RANGE] exs_sofid_o,
        output reg                  exs_ins_uerr_o,
        output reg                  exs_ins_ferr_o,
        output reg                  exs_jump_o,
        output reg                  exs_cond_o,
        output reg    [`ZONE_RANGE] exs_zone_o,
        output reg                  exs_link_o,
        output wire    [C_XLEN-1:0] exs_pc_o,
        output reg   [`ALUOP_RANGE] exs_alu_op_o,
        output reg     [C_XLEN-1:0] exs_operand_left_o,
        output reg     [C_XLEN-1:0] exs_operand_right_o,
        output wire    [C_XLEN-1:0] exs_regs1_data_o,
        output wire    [C_XLEN-1:0] exs_regs2_data_o,
        output reg            [4:0] exs_regd_addr_o,
        output reg            [2:0] exs_funct3_o,
        output reg                  exs_csr_access_o,
        output reg           [11:0] exs_csr_addr_o,
        output reg     [C_XLEN-1:0] exs_csr_wr_data_o,
            // write-back interface
        input  wire                 exs_regd_cncl_load_i,
        input  wire                 exs_regd_wr_i,
        input  wire           [4:0] exs_regd_addr_i,
        input  wire    [C_XLEN-1:0] exs_regd_data_i,
        // load/store queue interface
        input  wire                 lsq_reg_wr_i,
        input  wire           [4:0] lsq_reg_addr_i,
        input  wire    [C_XLEN-1:0] lsq_reg_data_i
    );

    //--------------------------------------------------------------

    // id stage qualifier logic
    // instruction decoder
    wire                ins_uerr_d;
    wire                jump_d;
    wire  [`ZONE_RANGE] zone_d;
    wire          [4:0] regd_addr_d;
    wire                regs1_rd;
    wire          [4:0] regs1_addr;
    wire                regs2_rd;
    wire          [4:0] regs2_addr;
    wire   [C_XLEN-1:0] imm_d;
    wire                link_d;
    wire                sels1_pc_d;
    wire                sel_csr_wr_data_imm_d;
    wire                sels2_imm_d;
    wire [`ALUOP_RANGE] alu_op_d;
    wire          [2:0] funct3_d;
    wire                csr_access_d;
    wire         [11:0] csr_addr_d;
    wire                conditional_d;
    // id stage stall controller
    wire                id_stage_en;
    reg                 ids_stall;
    reg          [31:1] reg_loading_vector_q;
    // integer register file
    wire   [C_XLEN-1:0] regs1_dout;
    wire   [C_XLEN-1:0] regs2_dout;
    // forwarding register
    reg                 fwd_regd_wr_q;
    reg           [4:0] fwd_regd_addr_q;
    reg    [C_XLEN-1:0] fwd_regd_data_q;
    // id register stage
    reg                 valid_q;
    reg    [C_XLEN-1:0] pc_q;
    reg                 ex_udefins_err_q;
    reg    [C_XLEN-1:0] imm_q;
    reg                 sels1_pc_q;
    reg                 sel_csr_wr_data_imm_q;
    reg                 sels2_imm_q;
    reg           [4:0] regs1_addr_q;
    reg           [4:0] regs2_addr_q;
    // operand forwarding mux
    reg    [C_XLEN-1:0] fwd_mux_regs1_data;
    reg    [C_XLEN-1:0] fwd_mux_regs2_data;
    // left operand select mux
    // right operand select mux
    // csr write data select mux

    //--------------------------------------------------------------

    // interface assignments
    assign exs_pc_o         = pc_q;
    assign exs_regs1_data_o = fwd_mux_regs1_data;
    assign exs_regs2_data_o = fwd_mux_regs2_data;


    // id stage qualifier logic
    //
    assign pfu_ack_o   = id_stage_en & pfu_dav_i;
    assign exs_valid_o = id_stage_en & valid_q;


    // instruction decoder
    //
    decoder
        #(
            .C_XLEN                (C_XLEN)
        ) i_decoder (
            // instruction decoder interface
                // ingress side
            .ins_i                 (pfu_ins_i),
                // egress side
            .ins_err_o             (ins_uerr_d),
            .jump_o                (jump_d),
            .zone_o                (zone_d),
            .regd_addr_o           (regd_addr_d),
            .regs1_rd_o            (regs1_rd),
            .regs1_addr_o          (regs1_addr),
            .regs2_rd_o            (regs2_rd),
            .regs2_addr_o          (regs2_addr),
            .imm_o                 (imm_d),
            .link_o                (link_d),
            .sels1_pc_o            (sels1_pc_d),
            .sel_csr_wr_data_imm_o (sel_csr_wr_data_imm_d),
            .sels2_imm_o           (sels2_imm_d),
            .aluop_o               (alu_op_d),
            .funct3_o              (funct3_d),
            .csr_access_o          (csr_access_d),
            .csr_addr_o            (csr_addr_d),
            .conditional_o         (conditional_d)
        );


    // id stage stall controller
    //
    /* *** RULES ***
     * No register can have more than one pending load at any given time
     *  - This is to prevent the flag being cleared prematuraly by the first load
     * No register can be targeted if it has a pending load
     *
     */
    assign id_stage_en = ~ids_stall & ~exs_stall_i;
    always @ (*)
    begin
        ids_stall = 1'b0;
        //
        if (pfu_dav_i) begin
            if ( (regs1_rd && reg_loading_vector_q[regs1_addr] ) ||
                 (regs2_rd && reg_loading_vector_q[regs2_addr] ) ||
                 (zone_d == `ZONE_REGFILE && reg_loading_vector_q[regd_addr_d] ) ) begin
                ids_stall = 1'b1;
            end
        end
    end
    always @ (posedge clk_i or negedge resetb_i)
    begin
        if (~resetb_i) begin
            reg_loading_vector_q <= 31'b0;
        end else if (clk_en_i) begin
            if ((exs_regd_cncl_load_i | lsq_reg_wr_i) && lsq_reg_addr_i != 0) begin
                reg_loading_vector_q[lsq_reg_addr_i] <= 1'b0;
            end else if (pfu_ack_o && zone_d == `ZONE_LOADQ) begin
                reg_loading_vector_q[regd_addr_d] <= 1'b1;
            end
        end
    end


    // integer register file
    //
    regfile_integer
        #(
            .C_XLEN        (C_XLEN)
        ) i_regfile_integer (
            // global
            .clk_i         (clk_i),
            .clk_en_i      (clk_en_i),
            .resetb_i      (resetb_i),
            // write port
            .wreg_a_wr_i   (exs_regd_wr_i),
            .wreg_a_addr_i (exs_regd_addr_i),
            .wreg_a_data_i (exs_regd_data_i),
            .wreg_b_wr_i   (lsq_reg_wr_i),
            .wreg_b_addr_i (lsq_reg_addr_i),
            .wreg_b_data_i (lsq_reg_data_i),
            // read port
            .rreg_a_rd_i   (regs1_rd),
            .rreg_a_addr_i (regs1_addr),
            .rreg_a_data_o (regs1_dout),
            .rreg_b_rd_i   (regs2_rd),
            .rreg_b_addr_i (regs2_addr),
            .rreg_b_data_o (regs2_dout)
        );


    // forwarding register
    //
    always @ (posedge clk_i or negedge resetb_i)
    begin
        if (~resetb_i) begin
            fwd_regd_wr_q   <= 1'b0;
            //fwd_regd_addr_q <= 5'b0; // NOTE: don't actually care
            //fwd_regd_data_q <= { C_XLEN {1'b0} }; // NOTE: don't actually care
        end else if (clk_en_i) begin
            fwd_regd_wr_q   <= exs_regd_wr_i;
            fwd_regd_addr_q <= exs_regd_addr_i;
            fwd_regd_data_q <= exs_regd_data_i;
        end
    end


    // id register stage
    //
    always @ (posedge clk_i or negedge resetb_i)
    begin
        if (~resetb_i) begin
            valid_q <= 1'b0;
        end else if (clk_en_i) begin
            if (id_stage_en) begin
                valid_q               <= pfu_ack_o;
                exs_sofid_o           <= pfu_sofid_i;
                exs_jump_o            <= jump_d;
                pc_q                  <= pfu_pc_i;
                exs_ins_uerr_o        <= ins_uerr_d;
                exs_ins_ferr_o        <= pfu_ferr_i;
                exs_zone_o            <= zone_d;
                exs_regd_addr_o       <= regd_addr_d;
                imm_q                 <= imm_d;
                exs_link_o            <= link_d;
                sels1_pc_q            <= sels1_pc_d;
                sel_csr_wr_data_imm_q <= sel_csr_wr_data_imm_d;
                sels2_imm_q           <= sels2_imm_d;
                exs_alu_op_o          <= alu_op_d;
                exs_funct3_o          <= funct3_d;
                exs_csr_access_o      <= csr_access_d;
                exs_csr_addr_o        <= csr_addr_d;
                exs_cond_o            <= conditional_d;
                // register addr delay register
                regs1_addr_q          <= regs1_addr;
                regs2_addr_q          <= regs2_addr;
            end
        end
    end


    // operand forwarding mux
    //
        // forwarding mux for s1
    always @ (*)
    begin
        if (regs1_addr_q == 0) begin
            // register x0 is always valid
            fwd_mux_regs1_data = regs1_dout;
        end else if (exs_regd_wr_i && exs_regd_addr_i == regs1_addr_q) begin
            // operand at alu output
            fwd_mux_regs1_data = exs_regd_data_i;
        end else if (fwd_regd_wr_q && fwd_regd_addr_q == regs1_addr_q) begin
            // operand at forwarding register output
            fwd_mux_regs1_data = fwd_regd_data_q;
        end else begin
            // operand at register file output
            fwd_mux_regs1_data = regs1_dout;
        end
    end
        // forwarding mux for s2
    always @ (*)
    begin
        if (regs2_addr_q == 0) begin
            // register x0 is always valid
            fwd_mux_regs2_data = regs2_dout;
        end else if (exs_regd_wr_i && exs_regd_addr_i == regs2_addr_q) begin
            // operand at alu output
            fwd_mux_regs2_data = exs_regd_data_i;
        end else if (fwd_regd_wr_q && fwd_regd_addr_q == regs2_addr_q) begin
            // operand at forwarding register output
            fwd_mux_regs2_data = fwd_regd_data_q;
        end else begin
            // operand at register file output
            fwd_mux_regs2_data = regs2_dout;
        end
    end


    // left operand select mux
    //
    always @ (*)
    begin
        if (sels1_pc_q) begin
            exs_operand_left_o = pc_q;
        end else begin
            exs_operand_left_o = fwd_mux_regs1_data;
        end
    end


    // right operand select mux
    //
    always @ (*)
    begin
        if (sels2_imm_q) begin
            exs_operand_right_o = imm_q;
        end else begin
            exs_operand_right_o = fwd_mux_regs2_data;
        end
    end


    // csr write data select mux
    //
    always @ (*)
    begin
        if (sel_csr_wr_data_imm_q) begin
            exs_csr_wr_data_o = imm_q;
        end else begin
            exs_csr_wr_data_o = fwd_mux_regs1_data;
        end
    end
endmodule