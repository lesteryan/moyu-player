// Toggle the physical display panel the same way scrcpy-server does for
// --turn-screen-off / MOD+o, by calling its Device.setDisplayPower via reflection.
// Run: CLASSPATH=<this dex jar>:<scrcpy-server.jar> app_process / ScreenPower on|off
public class ScreenPower {
    public static void main(String[] args) throws Exception {
        boolean on = "on".equals(args[0]);
        android.os.Looper.prepareMainLooper();
        Class.forName("com.genymobile.scrcpy.Workarounds").getMethod("apply").invoke(null);
        Object ok = Class.forName("com.genymobile.scrcpy.device.Device")
                .getMethod("setDisplayPower", int.class, boolean.class).invoke(null, 0, on);
        System.out.println("setDisplayPower(" + on + ") = " + ok);
    }
}
