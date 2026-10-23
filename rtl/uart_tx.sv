`timescale 1ns/1ps
// valid/ready handshake, 8-N-1, LSB first. DIV=round(clock_hz/baud).
module uart_tx #(parameter DIV=87)(
    input wire clk, reset, valid, input wire [7:0] data,
    output wire ready, output wire tx
);
    reg [9:0] shift;
    reg [3:0] remaining;
    reg [$clog2(DIV+1)-1:0] tick;
    assign ready=(remaining==0);
    assign tx=ready?1'b1:shift[0];
    always @(posedge clk) begin
        if(reset) begin shift<=10'h3ff; remaining<=0; tick<=0; end
        else if(ready) begin
            if(valid) begin shift<={1'b1,data,1'b0}; remaining<=10; tick<=DIV-1; end
        end else if(tick==0) begin
            shift<={1'b1,shift[9:1]}; remaining<=remaining-1; tick<=DIV-1;
        end else tick<=tick-1;
    end
endmodule
