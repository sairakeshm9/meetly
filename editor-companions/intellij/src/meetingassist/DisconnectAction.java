package meetingassist;
import com.intellij.openapi.actionSystem.AnAction;
import com.intellij.openapi.actionSystem.AnActionEvent;
public class DisconnectAction extends AnAction {
    @Override public void actionPerformed(AnActionEvent event) { ConnectAction.disconnect(); }
}
