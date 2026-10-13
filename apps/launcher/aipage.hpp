#ifndef AIPAGE_H
#define AIPAGE_H

#include <QElapsedTimer>
#include <QFile>
#include <QPointer>
#include <QProcess>
#include <QTimer>

#include <components/llm/server.hpp>

#include "ui_aipage.h"

class QNetworkAccessManager;
class QNetworkReply;

namespace Files
{
    struct ConfigurationManager;
}

namespace Launcher
{
    // Sets up AI dialogue: the device the model runs on, downloading a model, the [LLM] server settings,
    // and a test run of the bundled llama-server.
    class AiPage : public QWidget, private Ui::AiPage
    {
        Q_OBJECT

    public:
        explicit AiPage(const Files::ConfigurationManager& cfg, QWidget* parent = nullptr);
        ~AiPage() override;

        bool loadSettings();
        void saveSettings();

    private slots:
        void detectDevices();
        void browseModel();
        void updateCatalogue();
        void startDownload();
        void cancelDownload();
        void startTest();
        void updateMemoryEstimate();
        void openModelsFolder();
        void changeModelsFolder();

    private:
        struct CatalogueEntry
        {
            QString mName;
            QString mDescription;
            QString mRepo;
            QString mFile;
            qint64 mSize = 0;
            QString mSha256;
            int mMinVramMiB = 0;
            bool mAlternative = false;
        };

        void loadCatalogue();
        void refreshModels(const QString& select);
        void setDevices(const std::vector<LLM::Device>& devices);
        // Total video memory of the selected (or automatically chosen) GPU, 0 for the CPU or if unknown
        int selectedVramMiB() const;
        std::string selectedDevice() const;
        QString modelsDirectory() const;
        // Path of the model chosen in the list, empty if none is installed
        QString selectedModel() const;

        void onDownloadData();
        void onDownloadFinished();
        void verifyDownload(const QString& partPath, const CatalogueEntry& entry);
        void finishDownload(bool ok, const QString& message);

        void pollTestServer();
        void sendTestPrompt();
        void stopTest(const QString& status);

        const Files::ConfigurationManager& mCfgMgr;
        std::vector<CatalogueEntry> mCatalogue;
        std::vector<LLM::Device> mDevices;
        bool mDevicesKnown = false;
        QProcess* mDevicesProcess = nullptr;

        QNetworkAccessManager* mNetwork;
        QString mLayerCountModel;
        int mLayerCount = 0;

        // Download in progress
        QPointer<QNetworkReply> mDownloadReply;
        QFile mDownloadFile;
        CatalogueEntry mDownloadEntry;
        qint64 mDownloadOffset = 0;
        bool mDownloadCancelled = false;
        bool mDownloadChecked = false;
        QElapsedTimer mDownloadTimer;

        // Test run
        QProcess* mTestProcess = nullptr;
        QTimer mTestTimer;
        QElapsedTimer mTestElapsed;
        int mTestPort = 0;
        bool mTestPromptSent = false;
        QString mTestLog;
    };
}

#endif
