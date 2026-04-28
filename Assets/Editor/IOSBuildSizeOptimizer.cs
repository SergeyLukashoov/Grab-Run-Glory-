using System;
using System.IO;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;

public sealed class IOSBuildSizeOptimizer : IPreprocessBuildWithReport
{
    private const string ReportDirectory = "BuildReports";
    private const string ReportFileName = "ios-size-optimizer-report.txt";

    public int callbackOrder => -500;

    public void OnPreprocessBuild(BuildReport report)
    {
        if (report.summary.platform != BuildTarget.iOS)
            return;

        ApplyIOSPlayerSettings();
        SaveReport();
    }

    private static void ApplyIOSPlayerSettings()
    {
        PlayerSettings.stripEngineCode = true;
        PlayerSettings.SetIl2CppCompilerConfiguration(BuildTargetGroup.iOS, Il2CppCompilerConfiguration.Master);
        PlayerSettings.SetManagedStrippingLevel(BuildTargetGroup.iOS, ManagedStrippingLevel.High);
    }

    private static void SaveReport()
    {
        Directory.CreateDirectory(ReportDirectory);
        string outputPath = Path.Combine(ReportDirectory, ReportFileName);
        File.WriteAllText(
            outputPath,
            $"iOS optimizer executed at {DateTime.UtcNow:O}{Environment.NewLine}" +
            $"stripEngineCode: {PlayerSettings.stripEngineCode}{Environment.NewLine}" +
            $"managedStrippingLevel(iOS): {PlayerSettings.GetManagedStrippingLevel(BuildTargetGroup.iOS)}{Environment.NewLine}" +
            $"il2cppCompilerConfiguration(iOS): {PlayerSettings.GetIl2CppCompilerConfiguration(BuildTargetGroup.iOS)}{Environment.NewLine}"
        );
    }
}
