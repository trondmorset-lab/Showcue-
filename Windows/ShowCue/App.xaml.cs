using System.Windows;
using System.Windows.Threading;

namespace ShowCue;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        // Tallfelt skal følge Windows' språkinnstilling (norsk komma som desimaltegn).
        FrameworkElement.LanguageProperty.OverrideMetadata(typeof(FrameworkElement),
            new FrameworkPropertyMetadata(System.Windows.Markup.XmlLanguage.GetLanguage(
                System.Globalization.CultureInfo.CurrentCulture.IetfLanguageTag)));
        base.OnStartup(e);
    }

    private void OnUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        // Under et show skal programmet aldri krasje på grunn av én feil cue.
        MessageBox.Show(e.Exception.Message, "ShowCue – feil", MessageBoxButton.OK, MessageBoxImage.Warning);
        e.Handled = true;
    }
}
