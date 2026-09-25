import java.awt.CheckboxMenuItem;
import java.awt.Image;
import java.awt.Label;
import java.awt.Menu;
import java.awt.MenuItem;
import java.awt.SystemTray;
import java.awt.TrayIcon;
import java.awt.event.ActionEvent;
import java.awt.event.ItemEvent;
import java.awt.event.MouseEvent;
import java.awt.event.MouseListener;
import java.awt.image.BufferedImage;
import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.concurrent.atomic.AtomicReference;
import javax.imageio.ImageIO;
import javax.swing.ImageIcon;
import javax.swing.SwingUtilities;

/**
 * Runs the Q Pilot GUI and shows its AWT tray icon through the qpilot-tray
 * helper as a StatusNotifierItem, because XEmbed tray menus do not open on
 * Plasma under Wayland. Arguments go to the GUI unchanged, e.g.
 * "QPilotTrayBridge -joblist" runs the GUI's job list mode.
 *
 * Protocol with the helper: it first prints "available" or "unavailable";
 * the bridge then writes the tray state as JSON lines and reads back
 * "activate <path>\t<label>" (menu entry, path of item indices like "2/0")
 * or "open" (left click).
 */
public final class QPilotTrayBridge {
	private static final String GUI_MAIN = "com.schomaecker.qpilot.client.gui.ClientGUIApplication";
	private static final String HELPER =
		System.getProperty("qpilot.trayHelper", "/usr/libexec/qpilot-client/qpilot-tray");

	private final TrayIcon icon;
	private Writer toHelper;
	private Image sentImage;
	private String sentState = "";

	private QPilotTrayBridge(TrayIcon icon) {
		this.icon = icon;
	}

	public static void main(String[] args) throws Exception {
		Thread bridge = new Thread(QPilotTrayBridge::start, "TrayBridge");
		bridge.setDaemon(true);
		bridge.start();
		Class.forName(GUI_MAIN).getMethod("main", String[].class).invoke(null, (Object) args);
	}

	private static void start() {
		try {
			TrayIcon icon = waitForIcon();
			new QPilotTrayBridge(icon).run();
		} catch (Exception e) {
			System.err.println("TrayBridge: " + e);
		}
	}

	private static TrayIcon waitForIcon() throws InterruptedException {
		while (true) {
			if (SystemTray.isSupported()) {
				TrayIcon[] icons = SystemTray.getSystemTray().getTrayIcons();
				if (icons.length > 0) {
					return icons[0];
				}
			}
			Thread.sleep(500);
		}
	}

	private void run() throws Exception {
		Process helper = new ProcessBuilder(HELPER)
			.redirectError(ProcessBuilder.Redirect.INHERIT)
			.start();
		BufferedReader fromHelper = new BufferedReader(
			new InputStreamReader(helper.getInputStream(), StandardCharsets.UTF_8));
		if (!"available".equals(fromHelper.readLine())) {
			helper.destroy();
			return;
		}
		toHelper = new OutputStreamWriter(helper.getOutputStream(), StandardCharsets.UTF_8);
		SwingUtilities.invokeAndWait(() -> SystemTray.getSystemTray().remove(icon));

		Thread commands = new Thread(() -> readCommands(fromHelper), "TrayBridgeCommands");
		commands.setDaemon(true);
		commands.start();

		try {
			while (helper.isAlive()) {
				sendState();
				Thread.sleep(500);
			}
		} catch (IOException e) {
			System.err.println("TrayBridge: helper gone: " + e);
		}
		// Without the helper, the AWT icon is better than none.
		SwingUtilities.invokeAndWait(() -> {
			try {
				SystemTray.getSystemTray().add(icon);
			} catch (Exception e) {
				System.err.println("TrayBridge: " + e);
			}
		});
	}

	private void sendState() throws Exception {
		AtomicReference<String> menu = new AtomicReference<>();
		AtomicReference<Image> image = new AtomicReference<>();
		SwingUtilities.invokeAndWait(() -> {
			menu.set(menuJson(icon.getPopupMenu(), ""));
			image.set(icon.getImage());
		});
		String state = "\"tooltip\":" + json(icon.getToolTip()) + ",\"menu\":" + menu.get();
		boolean newImage = image.get() != sentImage;
		if (!newImage && state.equals(sentState)) {
			return;
		}
		StringBuilder line = new StringBuilder("{").append(state);
		if (newImage) {
			line.append(",\"icon\":").append(json(png(image.get())));
		}
		toHelper.write(line.append("}\n").toString());
		toHelper.flush();
		sentImage = image.get();
		sentState = state;
	}

	/** Menu as a JSON array, e.g. [{"path":"0","kind":"item","label":"Beenden","enabled":true}]. */
	private static String menuJson(Menu menu, String prefix) {
		StringBuilder out = new StringBuilder("[");
		for (int i = 0; menu != null && i < menu.getItemCount(); i++) {
			MenuItem item = menu.getItem(i);
			String path = prefix + i;
			if (i > 0) {
				out.append(',');
			}
			out.append("{\"path\":").append(json(path));
			if ("-".equals(item.getLabel())) {
				out.append(",\"kind\":\"separator\"}");
				continue;
			}
			out.append(",\"label\":").append(json(item.getLabel()))
				.append(",\"enabled\":").append(item.isEnabled());
			if (item instanceof Menu sub) {
				out.append(",\"kind\":\"submenu\",\"items\":").append(menuJson(sub, path + "/"));
			} else if (item instanceof CheckboxMenuItem check) {
				out.append(",\"kind\":\"check\",\"checked\":").append(check.getState());
			} else {
				out.append(",\"kind\":\"item\"");
			}
			out.append('}');
		}
		return out.append(']').toString();
	}

	private void readCommands(BufferedReader fromHelper) {
		try {
			String line;
			while ((line = fromHelper.readLine()) != null) {
				String command = line;
				SwingUtilities.invokeLater(() -> execute(command));
			}
		} catch (IOException e) {
			System.err.println("TrayBridge: " + e);
		}
	}

	private void execute(String command) {
		if (command.equals("open")) {
			MouseEvent click = new MouseEvent(new Label(), MouseEvent.MOUSE_CLICKED,
				System.currentTimeMillis(), 0, 0, 0, 2, false, MouseEvent.BUTTON1);
			click.setSource(icon);
			for (MouseListener l : icon.getMouseListeners()) {
				l.mouseClicked(click);
			}
			return;
		}
		if (!command.startsWith("activate ")) {
			return;
		}
		String[] parts = command.substring("activate ".length()).split("\t", 2);
		MenuItem item = find(icon.getPopupMenu(), parts[0]);
		// The menu may have been rebuilt since the helper showed it.
		if (item == null || parts.length < 2 || !parts[1].equals(item.getLabel()) || !item.isEnabled()) {
			return;
		}
		if (item instanceof CheckboxMenuItem check) {
			check.setState(!check.getState());
			check.dispatchEvent(new ItemEvent(check, ItemEvent.ITEM_STATE_CHANGED, check.getLabel(),
				check.getState() ? ItemEvent.SELECTED : ItemEvent.DESELECTED));
		} else {
			item.dispatchEvent(new ActionEvent(item, ActionEvent.ACTION_PERFORMED, item.getActionCommand()));
		}
	}

	private static MenuItem find(Menu menu, String path) {
		MenuItem item = null;
		for (String index : path.split("/")) {
			int i = Integer.parseInt(index);
			if (menu == null || i >= menu.getItemCount()) {
				return null;
			}
			item = menu.getItem(i);
			menu = item instanceof Menu sub ? sub : null;
		}
		return item;
	}

	private static String png(Image image) throws IOException {
		ImageIcon loaded = new ImageIcon(image);
		int w = Math.max(loaded.getIconWidth(), 1);
		int h = Math.max(loaded.getIconHeight(), 1);
		BufferedImage buffer = new BufferedImage(w, h, BufferedImage.TYPE_INT_ARGB);
		buffer.getGraphics().drawImage(loaded.getImage(), 0, 0, null);
		ByteArrayOutputStream out = new ByteArrayOutputStream();
		ImageIO.write(buffer, "png", out);
		return Base64.getEncoder().encodeToString(out.toByteArray());
	}

	private static String json(String s) {
		if (s == null) {
			return "\"\"";
		}
		StringBuilder out = new StringBuilder("\"");
		for (char c : s.toCharArray()) {
			switch (c) {
				case '"' -> out.append("\\\"");
				case '\\' -> out.append("\\\\");
				default -> {
					if (c < 0x20) {
						out.append(String.format("\\u%04x", (int) c));
					} else {
						out.append(c);
					}
				}
			}
		}
		return out.append('"').toString();
	}
}
