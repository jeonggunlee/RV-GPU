`timescale 1ns/1ps
module simt_alu(input wire [3:0] op, input wire [31:0] a,b,pc, output reg [31:0] y);
    always @* begin
        case(op)
            0:y=a+b; 1:y=a-b; 2:y=a<<b[4:0];
            3:y={31'b0,($signed(a)<$signed(b))}; 4:y={31'b0,(a<b)};
            5:y=a^b; 6:y=a>>b[4:0]; 7:y=$signed(a)>>>b[4:0];
            8:y=a|b; 9:y=a&b; 10:y=b; 11:y=pc+b;
            default:y=0;
        endcase
    end
endmodule
