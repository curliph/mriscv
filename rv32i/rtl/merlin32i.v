// TODO - generalise interface data widths

`include "riscv_defs.v"

module merlin32i
    #(
        parameter C_IRQV_SZ           = 32,
        parameter C_RESET_VECTOR      = 32'h0
    )
    (
        // global
        input  wire                  clk_i,
        input  wire                  clk_en_i,
        input  wire                  resetb_i,
        // hardware interrupt interface
        input  wire  [C_IRQV_SZ-1:0] irqv_i, // TODO
        // instruction port
        input  wire                  ireqready_i,
        output wire                  ireqvalid_o,
        output wire            [1:0] ireqhpl_o,
        output wire           [31:0] ireqaddr_o,
        output wire                  irspready_o,
        input  wire                  irspvalid_i,
        input  wire                  irsprerr_i,
        input  wire           [31:0] irspdata_i,
        // data port
        input  wire                  dreqready_i,
        output wire                  dreqvalid_o,
        output wire                  dreqdvalid_o,
        output wire            [1:0] dreqhpl_o,
        output wire           [31:0] dreqaddr_o,
        output wire           [31:0] dreqdata_o,
        output wire                  drspready_o,
        input  wire                  drspvalid_i,
        input  wire                  drsprerr_i,
        input  wire                  drspwerr_i,
        input  wire           [31:0] drspdata_i
        // debug interface
        // TODO - debug interface
    );

    //--------------------------------------------------------------

    // hart vectoring and exception controller
    wire                hvec_pfu_pc_wr;
    wire [`RV_XLEN-1:0] hvec_pfu_pc;
    // prefetch unit
    wire                pfu_hvec_ready;
    wire                pfu_ids_dav;
    wire [`SOFID_RANGE] pfu_ids_sofid;
    wire [`RV_XLEN-1:0] pfu_ids_ins;
    wire                pfu_ids_ferr;
    wire [`RV_XLEN-1:0] pfu_ids_pc;
    // instruction decoder stage
    wire                ids_pfu_ack;
    wire                ids_exs_valid;
    wire [`SOFID_RANGE] ids_exs_sofid;
    wire                ids_exs_ins_uerr;
    wire                ids_exs_ins_ferr;
    wire                ids_exs_jump;
    wire                ids_exs_cond;
    wire  [`ZONE_RANGE] ids_exs_zone;
    wire                ids_exs_link;
    wire [`RV_XLEN-1:0] ids_exs_pc;
    wire [`ALUOP_RANGE] ids_exs_alu_op;
    wire [`RV_XLEN-1:0] ids_exs_operand_left;
    wire [`RV_XLEN-1:0] ids_exs_operand_right;
    wire [`RV_XLEN-1:0] ids_exs_regs1_data;
    wire [`RV_XLEN-1:0] ids_exs_regs2_data;
    wire          [4:0] ids_exs_regd_addr;
    wire          [2:0] ids_exs_funct3;
    wire                ids_exs_csr_rd;
    wire                ids_exs_csr_wr;
    wire         [11:0] ids_exs_csr_addr;
    wire [`RV_XLEN-1:0] ids_exs_csr_wr_data;
    wire          [4:0] lsq_ids_reg_addr;
    wire [`RV_XLEN-1:0] lsq_ids_reg_data;
    // execution stage
    wire          [1:0] exs_pfu_hpl;
    wire                exs_ids_stall;
    wire                exs_ids_regd_cncl_load;
    wire                exs_ids_regd_wr;
    wire          [4:0] exs_ids_regd_addr;
    wire [`RV_XLEN-1:0] exs_ids_regd_data;
    wire                exs_hvec_jump;
    wire [`RV_XLEN-1:0] exs_hvec_jump_addr;
    wire                exs_lsq_lq_wr;
    wire                exs_lsq_sq_wr;
    wire          [1:0] exs_lsq_hpl;
    wire          [2:0] exs_lsq_funct3;
    wire          [4:0] exs_lsq_regd_addr;
    wire [`RV_XLEN-1:0] exs_lsq_regs2_data;
    wire [`RV_XLEN-1:0] exs_lsq_addr;
    // load/store queue interface
    wire                lsq_exs_full;
    wire                lsq_ids_reg_wr;

    //--------------------------------------------------------------


    // hart vectoring and exception controller
    //
    hvec i_hvec (
            // global
            .clk_i           (clk_i),
            .clk_en_i        (clk_en_i),
            .resetb_i        (resetb_i),
            // external interrupt interface
            // pfu interface
            .pfu_pc_ready_i  (pfu_hvec_ready),
            .pfu_pc_wr_o     (hvec_pfu_pc_wr),
            .pfu_pc_o        (hvec_pfu_pc),
            // ex stage interface
            .exs_jump_i      (exs_hvec_jump),
            .exs_jump_addr_i (exs_hvec_jump_addr)
            // lsq interface
        );


    // prefetch unit
    //
    pfu
        #(
            .C_BUS_SZX      (5), // bus width base 2 exponent
            .C_FIFO_DEPTH_X (2), // pfu fifo depth base 2 exponent
            .C_RESET_VECTOR (32'h00000000)
        ) i_pfu (
            // global
            .clk_i           (clk_i),
            .clk_en_i        (clk_en_i),
            .resetb_i        (resetb_i),
            // instruction cache interface
            .ireqready_i     (ireqready_i),
            .ireqvalid_o     (ireqvalid_o),
            .ireqhpl_o       (ireqhpl_o), // HART priv. level
            .ireqaddr_o      (ireqaddr_o),
            .irspready_o     (irspready_o),
            .irspvalid_i     (irspvalid_i),
            .irsprerr_i      (irsprerr_i),
            .irspdata_i      (irspdata_i),
            // decoder interface
            .ids_dav_o       (pfu_ids_dav),   // new fetch available
            .ids_ack_i       (ids_pfu_ack),   // ack this fetch
            .ids_sofid_o     (pfu_ids_sofid), // first fetch since vectoring
            .ids_ins_o       (pfu_ids_ins),   // instruction fetched
            .ids_ferr_o      (pfu_ids_ferr),  // this instruction fetch resulted in error
            .ids_pc_o        (pfu_ids_pc),    // address of this instruction
            // vectoring and exception controller interface
            .hvec_pc_ready_o (pfu_hvec_ready),
            .hvec_pc_wr_i    (hvec_pfu_pc_wr),
            .hvec_pc_din_i   (hvec_pfu_pc),
            // pfu stage interface
            .exs_hpl_i       (exs_pfu_hpl)
        );


    // instruction decoder stage
    //
    id_stage i_id_stage (
            // global
            .clk_i                (clk_i),
            .clk_en_i             (clk_en_i),
            .resetb_i             (resetb_i),
            // pfu interface
            .pfu_dav_i            (pfu_ids_dav),   // new fetch available
            .pfu_ack_o            (ids_pfu_ack),   // ack this fetch
            .pfu_sofid_i          (pfu_ids_sofid), // first fetch since vectoring
            .pfu_ins_i            (pfu_ids_ins),   // instruction fetched
            .pfu_ferr_i           (pfu_ids_ferr),  // this instruction fetch resulted in error
            .pfu_pc_i             (pfu_ids_pc),    // address of this instruction
            // ex stage interface
            .exs_valid_o          (ids_exs_valid),
            .exs_stall_i          (exs_ids_stall),
            .exs_sofid_o          (ids_exs_sofid),
            .exs_ins_uerr_o       (ids_exs_ins_uerr),
            .exs_ins_ferr_o       (ids_exs_ins_ferr),
            .exs_jump_o           (ids_exs_jump),
            .exs_cond_o           (ids_exs_cond),
            .exs_zone_o           (ids_exs_zone),
            .exs_link_o           (ids_exs_link),
            .exs_pc_o             (ids_exs_pc),
            .exs_alu_op_o         (ids_exs_alu_op),
            .exs_operand_left_o   (ids_exs_operand_left),
            .exs_operand_right_o  (ids_exs_operand_right),
            .exs_regs1_data_o     (ids_exs_regs1_data),
            .exs_regs2_data_o     (ids_exs_regs2_data),
            .exs_regd_addr_o      (ids_exs_regd_addr),
            .exs_funct3_o         (ids_exs_funct3),
            .exs_csr_rd_o         (ids_exs_csr_rd),
            .exs_csr_wr_o         (ids_exs_csr_wr),
            .exs_csr_addr_o       (ids_exs_csr_addr),
            .exs_csr_wr_data_o    (ids_exs_csr_wr_data),
                // write-back interface
            .exs_regd_cncl_load_i (exs_ids_regd_cncl_load),
            .exs_regd_wr_i        (exs_ids_regd_wr),
            .exs_regd_addr_i      (exs_ids_regd_addr),
            .exs_regd_data_i      (exs_ids_regd_data),
            // load/store queue interface
            .lsq_reg_wr_i         (lsq_ids_reg_wr),
            .lsq_reg_addr_i       (lsq_ids_reg_addr),
            .lsq_reg_data_i       (lsq_ids_reg_data)
        );


    // execution stage
    //
    ex_stage i_ex_stage (
            // global
            .clk_i                (clk_i),
            .clk_en_i             (clk_en_i),
            .resetb_i             (resetb_i),
            // pfu stage interface
            .pfu_hpl_o            (exs_pfu_hpl),
            // instruction decoder stage interface
            .ids_valid_i          (ids_exs_valid),
            .ids_stall_o          (exs_ids_stall),
            .ids_sofid_i          (ids_exs_sofid),
            .ids_ins_uerr_i       (ids_exs_ins_uerr),
            .ids_ins_ferr_i       (ids_exs_ins_ferr),
            .ids_jump_i           (ids_exs_jump),
            .ids_cond_i           (ids_exs_cond),
            .ids_zone_i           (ids_exs_zone),
            .ids_link_i           (ids_exs_link),
            .ids_pc_i             (ids_exs_pc),
            .ids_alu_op_i         (ids_exs_alu_op),
            .ids_operand_left_i   (ids_exs_operand_left),
            .ids_operand_right_i  (ids_exs_operand_right),
            .ids_regs1_data_i     (ids_exs_regs1_data),
            .ids_regs2_data_i     (ids_exs_regs2_data),
            .ids_regd_addr_i      (ids_exs_regd_addr),
            .ids_funct3_i         (ids_exs_funct3),
            .ids_csr_rd_i         (ids_exs_csr_rd),
            .ids_csr_wr_i         (ids_exs_csr_wr),
            .ids_csr_addr_i       (ids_exs_csr_addr),
            .ids_csr_wr_data_i    (ids_exs_csr_wr_data),
                // write-back interface
            .ids_regd_cncl_load_o (exs_ids_regd_cncl_load),
            .ids_regd_wr_o        (exs_ids_regd_wr),
            .ids_regd_addr_o      (exs_ids_regd_addr),
            .ids_regd_data_o      (exs_ids_regd_data),
            // hart vectoring and exception controller interface TODO
            .hvec_ferr_o          (),
            .hvec_uerr_o          (),
            .hvec_maif_o          (),
            .hvec_mala_o          (),
            .hvec_masa_o          (),
            .hvec_ilgl_o          (),
            .hvec_jump_o          (exs_hvec_jump),
            .hvec_jump_addr_o     (exs_hvec_jump_addr),
            // load/store queue interface
            .lsq_full_i           (lsq_exs_full),
            .lsq_lq_wr_o          (exs_lsq_lq_wr),
            .lsq_sq_wr_o          (exs_lsq_sq_wr),
            .lsq_hpl_o            (exs_lsq_hpl),
            .lsq_funct3_o         (exs_lsq_funct3),
            .lsq_regd_addr_o      (exs_lsq_regd_addr),
            .lsq_regs2_data_o     (exs_lsq_regs2_data),
            .lsq_addr_o           (exs_lsq_addr)
        );


        // load/store queue
        //
        lsqueue
            #(
                .C_FIFO_DEPTH_X   (2)
            ) i_lsqueue (
                // global
                .clk_i            (clk_i),
                .clk_en_i         (clk_en_i),
                .resetb_i         (resetb_i),
                // instruction decoder stage interface
                .lsq_reg_wr_o     (lsq_ids_reg_wr),
                .lsq_reg_addr_o   (lsq_ids_reg_addr),
                .lsq_reg_data_o   (lsq_ids_reg_data),
                // execution stage interface
                .exs_full_o       (lsq_exs_full),
                .exs_lq_wr_i      (exs_lsq_lq_wr),
                .exs_sq_wr_i      (exs_lsq_sq_wr),
                .exs_hpl_i        (exs_lsq_hpl),
                .exs_funct3_i     (exs_lsq_funct3),
                .exs_regd_addr_i  (exs_lsq_regd_addr),
                .exs_regs2_data_i (exs_lsq_regs2_data),
                .exs_addr_i       (exs_lsq_addr),
                // data port
                .dreqready_i      (dreqready_i),
                .dreqvalid_o      (dreqvalid_o),
                .dreqdvalid_o     (dreqdvalid_o),
                .dreqhpl_o        (dreqhpl_o),
                .dreqaddr_o       (dreqaddr_o),
                .dreqdata_o       (dreqdata_o),
                .drspready_o      (drspready_o),
                .drspvalid_i      (drspvalid_i),
                .drsprerr_i       (drsprerr_i),
                .drspwerr_i       (drspwerr_i),
                .drspdata_i       (drspdata_i),
                // hart vectoring and exception controller interface TODO
                .hvec_laf_o       (), // load access fault
                .hvec_saf_o       (), // store access fault
                .hvec_badaddr_o   ()  // bad address
            );
endmodule

