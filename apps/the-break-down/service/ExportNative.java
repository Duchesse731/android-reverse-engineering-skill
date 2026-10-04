// Ghidra post-analysis script. Writes recoverable pseudocode and explicit failures.
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.*;
import ghidra.program.model.listing.*;
import java.io.*;
public class ExportNative extends GhidraScript {
  public void run() throws Exception {
    DecompInterface decompiler = new DecompInterface();
    try (PrintWriter writer = new PrintWriter(getScriptArgs()[0], "UTF-8")) {
      if (!decompiler.openProgram(currentProgram)) throw new IOException("Cannot open native program");
      FunctionIterator functions = currentProgram.getFunctionManager().getFunctions(true);
      int count = 0;
      while (functions.hasNext() && count++ < 500 && !monitor.isCancelled()) {
        Function function = functions.next();
        DecompileResults result = decompiler.decompileFunction(function, 10, monitor);
        if (result.decompileCompleted()) writer.println(result.getDecompiledFunction().getC());
        else writer.println("/* Unresolved function: " + function.getEntryPoint() + " */");
      }
      if (functions.hasNext()) writer.println("/* Output limited to 500 functions. */");
    } finally { decompiler.dispose(); }
  }
}
