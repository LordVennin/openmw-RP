#include "aipage.hpp"

#include <thread>

#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDesktopServices>
#include <QDir>
#include <QFileDialog>
#include <QFileInfo>
#include <QHeaderView>
#include <QHostAddress>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QStorageInfo>
#include <QTcpServer>

#include <components/files/configurationmanager.hpp>
#include <components/files/conversion.hpp>
#include <components/files/qtconversion.hpp>
#include <components/settings/values.hpp>

namespace
{
    constexpr int sContextSizes[] = { 4096, 8192, 16384, 32768 };
    // Rough KV cache size of a 12-16B model per token of context, for the memory estimate
    constexpr qint64 sBytesPerContextToken = 192 * 1024;
    constexpr int sTestTimeoutSeconds = 600;
    constexpr int sTestReplyTokens = 48;

    QString formatGigabytes(qint64 bytes)
    {
        return QString::number(bytes / 1e9, 'f', 1) + QStringLiteral(" GB");
    }

    QString formatMiB(int mib)
    {
        return QString::number(mib / 1024.0, 'f', 0) + QStringLiteral(" GB");
    }
}

Launcher::AiPage::AiPage(const Files::ConfigurationManager& cfg, QWidget* parent)
    : QWidget(parent)
    , mCfgMgr(cfg)
    , mNetwork(new QNetworkAccessManager(this))
{
    setObjectName("AiPage");
    setupUi(this);

    catalogueTree->header()->setStretchLastSection(true);
    downloadProgressBar->setRange(0, 1000);
    downloadProgressBar->setVisible(false);
    cancelDownloadButton->setVisible(false);
    testOutput->setVisible(false);
    mTestTimer.setInterval(500);

    for (int size : sContextSizes)
        contextSizeComboBox->addItem(QString::number(size / 1024) + QStringLiteral("K"), size);

    loadCatalogue();

    connect(refreshDevicesButton, &QPushButton::clicked, this, &AiPage::detectDevices);
    connect(browseModelButton, &QPushButton::clicked, this, &AiPage::browseModel);
    connect(downloadButton, &QPushButton::clicked, this, &AiPage::startDownload);
    connect(cancelDownloadButton, &QPushButton::clicked, this, &AiPage::cancelDownload);
    connect(testButton, &QPushButton::clicked, this, &AiPage::startTest);
    connect(&mTestTimer, &QTimer::timeout, this, &AiPage::pollTestServer);
    connect(deviceComboBox, qOverload<int>(&QComboBox::currentIndexChanged), this, &AiPage::updateCatalogue);
    connect(deviceComboBox, qOverload<int>(&QComboBox::currentIndexChanged), this, &AiPage::updateMemoryEstimate);
    connect(modelComboBox, qOverload<int>(&QComboBox::currentIndexChanged), this, &AiPage::updateMemoryEstimate);
    connect(contextSizeComboBox, qOverload<int>(&QComboBox::currentIndexChanged), this, &AiPage::updateMemoryEstimate);
    connect(gpuLayersSpinBox, qOverload<int>(&QSpinBox::valueChanged), this, &AiPage::updateMemoryEstimate);
    connect(openModelsFolderButton, &QPushButton::clicked, this, &AiPage::openModelsFolder);
    connect(changeModelsFolderButton, &QPushButton::clicked, this, &AiPage::changeModelsFolder);
    connect(catalogueTree, &QTreeWidget::currentItemChanged, this,
        [this] { downloadButton->setEnabled(catalogueTree->currentItem() != nullptr && !mDownloadReply); });
}

Launcher::AiPage::~AiPage()
{
    if (mDownloadReply)
    {
        mDownloadReply->disconnect(this);
        mDownloadReply->abort();
    }
    stopTest({});
    if (mDevicesProcess != nullptr)
        mDevicesProcess->kill();
}

bool Launcher::AiPage::loadSettings()
{
    const Settings::LlmCategory& llm = Settings::llm();
    autostartCheckBox->setChecked(llm.mServerAutostart);
    gpuLayersSpinBox->setValue(llm.mGpuLayers);
    vramReserveSpinBox->setValue(llm.mVramReserveMiB / 1024.0);
    portSpinBox->setValue(llm.mPort);
    extraArgumentsLineEdit->setText(QString::fromStdString(llm.mExtraArguments));

    const int contextSize = llm.mContextSize;
    int contextIndex = contextSizeComboBox->findData(contextSize);
    if (contextIndex < 0)
    {
        contextSizeComboBox->addItem(QString::number(contextSize), contextSize);
        contextIndex = contextSizeComboBox->count() - 1;
    }
    contextSizeComboBox->setCurrentIndex(contextIndex);

    refreshModels(QString::fromStdString(llm.mModel));
    setDevices(mDevices);
    detectDevices();
    return true;
}

void Launcher::AiPage::saveSettings()
{
    Settings::LlmCategory& llm = Settings::llm();
    llm.mServerAutostart.set(autostartCheckBox->isChecked());
    llm.mDevice.set(deviceComboBox->currentData().toString().toStdString());
    llm.mModel.set(modelComboBox->currentData().toString().toStdString());
    llm.mContextSize.set(contextSizeComboBox->currentData().toInt());
    llm.mGpuLayers.set(gpuLayersSpinBox->value());
    llm.mVramReserveMiB.set(static_cast<int>(vramReserveSpinBox->value() * 1024));
    llm.mPort.set(portSpinBox->value());
    llm.mExtraArguments.set(extraArgumentsLineEdit->text().trimmed().toStdString());
}

QString Launcher::AiPage::modelsDirectory() const
{
    return Files::pathToQString(LLM::modelsDir(mCfgMgr.getLocalPath(), mCfgMgr.getUserDataPath()));
}

QString Launcher::AiPage::selectedModel() const
{
    return modelComboBox->currentData().toString();
}

void Launcher::AiPage::openModelsFolder()
{
    QDir().mkpath(modelsDirectory());
    QDesktopServices::openUrl(QUrl::fromLocalFile(modelsDirectory()));
}

void Launcher::AiPage::changeModelsFolder()
{
    const QString folder = QFileDialog::getExistingDirectory(this, tr("Folder for AI models"), modelsDirectory());
    if (folder.isEmpty())
        return;
    // Applied right away, like the other settings it is saved when the launcher closes or the game starts
    Settings::llm().mModelsFolder.set(folder.toStdString());
    refreshModels(selectedModel());
}

void Launcher::AiPage::loadCatalogue()
{
    QFile file(QStringLiteral(":/llm/models.json"));
    if (!file.open(QIODevice::ReadOnly))
        return;
    const QJsonArray models = QJsonDocument::fromJson(file.readAll()).object().value("models").toArray();
    for (const QJsonValue& value : models)
    {
        const QJsonObject model = value.toObject();
        mCatalogue.push_back(CatalogueEntry{ model.value("name").toString(), model.value("description").toString(),
            model.value("repo").toString(), model.value("file").toString(),
            static_cast<qint64>(model.value("size").toDouble()), model.value("sha256").toString(),
            model.value("minVramMiB").toInt(), model.value("alternative").toBool() });
    }
}

// Device detection

void Launcher::AiPage::detectDevices()
{
    const QString server = Files::pathToQString(LLM::serverPath(mCfgMgr.getLocalPath()));
    if (!QFileInfo::exists(server))
    {
        devicesStatusLabel->setText(tr("llama-server was not found at %1, so AI dialogue can't run.").arg(server));
        return;
    }
    if (mDevicesProcess != nullptr)
        return;
    devicesStatusLabel->setText(tr("Looking for GPUs…"));
    refreshDevicesButton->setEnabled(false);
    mDevicesProcess = new QProcess(this);
    mDevicesProcess->setProcessChannelMode(QProcess::MergedChannels);
    connect(mDevicesProcess, &QProcess::finished, this, [this] {
        const QByteArray output = mDevicesProcess->readAll();
        mDevicesProcess->deleteLater();
        mDevicesProcess = nullptr;
        refreshDevicesButton->setEnabled(true);
        mDevicesKnown = true;
        setDevices(LLM::parseDevices(output.toStdString()));
    });
    connect(mDevicesProcess, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error != QProcess::FailedToStart)
            return;
        devicesStatusLabel->setText(tr("Could not run llama-server to detect GPUs."));
        mDevicesProcess->deleteLater();
        mDevicesProcess = nullptr;
        refreshDevicesButton->setEnabled(true);
    });
    mDevicesProcess->start(server, { QStringLiteral("--list-devices") });
}

void Launcher::AiPage::setDevices(const std::vector<LLM::Device>& devices)
{
    mDevices = devices;
    const QString current = deviceComboBox->count() > 0 ? deviceComboBox->currentData().toString()
                                                        : QString::fromStdString(Settings::llm().mDevice);

    QSignalBlocker blocker(deviceComboBox);
    deviceComboBox->clear();
    const std::string automatic = LLM::chooseDevice(mDevices);
    QString automaticText = tr("Automatic");
    if (mDevicesKnown)
        automaticText += automatic == "cpu" ? tr(" (CPU)") : QStringLiteral(" (%1)").arg(QString::fromStdString(automatic));
    deviceComboBox->addItem(automaticText, QStringLiteral("auto"));
    deviceComboBox->addItem(tr("CPU only (slow)"), QStringLiteral("cpu"));
    for (const LLM::Device& device : mDevices)
        deviceComboBox->addItem(QStringLiteral("%1: %2, %3")
                                    .arg(QString::fromStdString(device.mName), QString::fromStdString(device.mDescription),
                                        formatMiB(device.mTotalMiB)),
            QString::fromStdString(device.mName));

    int index = deviceComboBox->findData(current.isEmpty() ? QStringLiteral("auto") : current);
    if (index < 0)
    {
        // A device that isn't detected (yet): keep the setting
        deviceComboBox->addItem(current, current);
        index = deviceComboBox->count() - 1;
    }
    deviceComboBox->setCurrentIndex(index);

    if (mDevicesKnown)
    {
        if (mDevices.empty())
            devicesStatusLabel->setText(tr("No GPU found. The model will run on the CPU, which is much slower."));
        else
        {
            QStringList names;
            for (const LLM::Device& device : mDevices)
                names << QStringLiteral("%1 (%2)").arg(
                    QString::fromStdString(device.mDescription), QString::fromStdString(device.mBackend));
            devicesStatusLabel->setText(tr("Found: %1").arg(names.join(QStringLiteral(", "))));
        }
    }
    updateCatalogue();
    updateMemoryEstimate();
}

std::string Launcher::AiPage::selectedDevice() const
{
    const std::string device = deviceComboBox->currentData().toString().toStdString();
    if (device.empty() || device == "auto")
        return LLM::chooseDevice(mDevices);
    return device;
}

int Launcher::AiPage::selectedVramMiB() const
{
    const std::string device = selectedDevice();
    for (const LLM::Device& candidate : mDevices)
        if (candidate.mName == device)
            return candidate.mTotalMiB;
    return 0;
}

// Models

void Launcher::AiPage::refreshModels(const QString& select)
{
    QSignalBlocker blocker(modelComboBox);
    modelComboBox->clear();
    for (const std::filesystem::path& model : LLM::installedModels(Files::pathFromQString(modelsDirectory())))
    {
        const QString path = Files::pathToQString(model);
        modelComboBox->addItem(QFileInfo(path).fileName(), path);
    }
    int index = modelComboBox->findData(select);
    if (index < 0 && !select.isEmpty())
    {
        modelComboBox->addItem(QFileInfo(select).fileName(), select);
        index = modelComboBox->count() - 1;
    }
    if (modelComboBox->count() == 0)
        modelComboBox->addItem(tr("No model installed: download one below"), QString());
    // Without a saved choice, the game uses the first model, so show that one
    modelComboBox->setCurrentIndex(std::max(index, 0));
    modelsFolderLabel->setText(QDir::toNativeSeparators(modelsDirectory()));
    modelsFolderLabel->setToolTip(modelsFolderLabel->text());
    updateCatalogue();
    updateMemoryEstimate();
}

void Launcher::AiPage::browseModel()
{
    const QString path = QFileDialog::getOpenFileName(
        this, tr("Select a model"), modelsDirectory(), tr("GGUF models (*.gguf);;All files (*)"));
    if (!path.isEmpty())
        refreshModels(path);
}

void Launcher::AiPage::updateCatalogue()
{
    const int vram = selectedVramMiB();
    const bool onCpu = mDevicesKnown && selectedDevice() == "cpu";

    // Recommended: the largest main model that fits, or the smallest if none does
    int recommended = -1;
    for (std::size_t i = 0; i < mCatalogue.size(); ++i)
    {
        if (mCatalogue[i].mAlternative)
            continue;
        if (recommended < 0 || (vram >= mCatalogue[i].mMinVramMiB && vram < mCatalogue[recommended].mMinVramMiB))
            recommended = static_cast<int>(i);
        else if (vram < mCatalogue[recommended].mMinVramMiB && mCatalogue[i].mSize < mCatalogue[recommended].mSize)
            recommended = static_cast<int>(i);
    }

    const int selectedRow = catalogueTree->currentItem() != nullptr
        ? catalogueTree->indexOfTopLevelItem(catalogueTree->currentItem())
        : -1;
    catalogueTree->clear();
    const QDir models(modelsDirectory());
    for (std::size_t i = 0; i < mCatalogue.size(); ++i)
    {
        const CatalogueEntry& entry = mCatalogue[i];
        QString fit;
        if (QFileInfo::exists(models.filePath(entry.mFile)))
            fit = tr("Installed");
        else if (onCpu)
            fit = tr("Runs on the CPU (slow)");
        else if (vram == 0)
            fit.clear();
        else if (vram >= entry.mMinVramMiB)
            fit = tr("Fits");
        else if (vram >= entry.mSize / (1024 * 1024) + 1536)
            fit = tr("Tight: little memory left for the game");
        else
            fit = tr("Too large: partly on the CPU, slower");
        if (static_cast<int>(i) == recommended && vram > 0)
            fit = tr("Recommended. %1").arg(fit);

        auto* item = new QTreeWidgetItem({ entry.mName, formatGigabytes(entry.mSize), fit });
        item->setToolTip(0, entry.mDescription);
        if (static_cast<int>(i) == recommended && vram > 0)
        {
            QFont font = item->font(0);
            font.setBold(true);
            item->setFont(0, font);
        }
        catalogueTree->addTopLevelItem(item);
    }
    catalogueTree->resizeColumnToContents(0);
    catalogueTree->resizeColumnToContents(1);
    const int row = selectedRow >= 0 ? selectedRow : recommended;
    if (row >= 0 && row < catalogueTree->topLevelItemCount())
        catalogueTree->setCurrentItem(catalogueTree->topLevelItem(row));
    downloadButton->setEnabled(catalogueTree->currentItem() != nullptr && !mDownloadReply);
}

void Launcher::AiPage::updateMemoryEstimate()
{
    const QString model = selectedModel();
    const qint64 modelSize = model.isEmpty() ? 0 : QFileInfo(model).size();
    vramReserveSpinBox->setEnabled(gpuLayersSpinBox->value() == LLM::sAutoGpuLayers);
    if (modelSize == 0)
    {
        memoryEstimateLabel->clear();
        gpuLayersInfoLabel->clear();
        return;
    }
    if (model != mLayerCountModel)
    {
        mLayerCountModel = model;
        mLayerCount = LLM::layerCount(Files::pathFromQString(model)).value_or(0);
    }
    if (mLayerCount > 0)
    {
        gpuLayersSpinBox->setMaximum(mLayerCount + 1); // llama.cpp counts the output layer too
        gpuLayersInfoLabel->setText(gpuLayersSpinBox->value() == LLM::sAutoGpuLayers
                ? tr("As many of the %1 layers as fit").arg(mLayerCount + 1)
                : tr("of %1 layers").arg(mLayerCount + 1));
    }
    const qint64 total = modelSize + contextSizeComboBox->currentData().toLongLong() * sBytesPerContextToken;
    QString text = tr("About %1 of video memory").arg(formatGigabytes(total));
    const int vram = selectedVramMiB();
    if (vram > 0 && total > static_cast<qint64>(vram) * 1024 * 1024)
        text += tr(" (more than this GPU has)");
    memoryEstimateLabel->setText(text);
}

// Downloads

void Launcher::AiPage::startDownload()
{
    QTreeWidgetItem* item = catalogueTree->currentItem();
    if (item == nullptr || mDownloadReply)
        return;
    mDownloadEntry = mCatalogue[catalogueTree->indexOfTopLevelItem(item)];

    const QDir models(modelsDirectory());
    if (!models.mkpath(QStringLiteral(".")))
    {
        downloadStatusLabel->setText(tr("Could not create %1.").arg(models.path()));
        return;
    }
    if (QFileInfo::exists(models.filePath(mDownloadEntry.mFile)))
    {
        downloadStatusLabel->setText(tr("%1 is already installed.").arg(mDownloadEntry.mName));
        return;
    }

    mDownloadFile.setFileName(models.filePath(mDownloadEntry.mFile + QStringLiteral(".part")));
    if (!mDownloadFile.open(QIODevice::ReadWrite | QIODevice::Append))
    {
        downloadStatusLabel->setText(tr("Could not write %1.").arg(mDownloadFile.fileName()));
        return;
    }
    mDownloadOffset = mDownloadFile.size();
    if (mDownloadOffset >= mDownloadEntry.mSize)
    {
        // Downloaded earlier but not verified
        mDownloadFile.close();
        verifyDownload(mDownloadFile.fileName(), mDownloadEntry);
        return;
    }
    const qint64 needed = mDownloadEntry.mSize - mDownloadOffset;
    if (QStorageInfo(models.path()).bytesAvailable() < needed)
    {
        mDownloadFile.close();
        downloadStatusLabel->setText(
            tr("Not enough disk space: %1 needed in %2.").arg(formatGigabytes(needed), models.path()));
        return;
    }

    QNetworkRequest request(QUrl(QStringLiteral("https://huggingface.co/%1/resolve/main/%2")
                                     .arg(mDownloadEntry.mRepo, mDownloadEntry.mFile)));
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
    request.setHeader(QNetworkRequest::UserAgentHeader, QStringLiteral("OpenMW-launcher"));
    if (mDownloadOffset > 0)
        request.setRawHeader("Range", "bytes=" + QByteArray::number(mDownloadOffset) + "-");

    mDownloadCancelled = false;
    mDownloadChecked = false;
    mDownloadTimer.start();
    mDownloadReply = mNetwork->get(request);
    connect(mDownloadReply, &QNetworkReply::readyRead, this, &AiPage::onDownloadData);
    connect(mDownloadReply, &QNetworkReply::finished, this, &AiPage::onDownloadFinished);
    connect(mDownloadReply, &QNetworkReply::downloadProgress, this, [this](qint64 received, qint64 /*total*/) {
        const qint64 done = mDownloadOffset + received;
        downloadProgressBar->setValue(static_cast<int>(done * 1000 / std::max<qint64>(1, mDownloadEntry.mSize)));
        const double seconds = std::max<qint64>(1, mDownloadTimer.elapsed()) / 1000.0;
        const double speed = received / seconds;
        QString status = tr("Downloading %1: %2 of %3")
                             .arg(mDownloadEntry.mName, formatGigabytes(done), formatGigabytes(mDownloadEntry.mSize));
        if (speed > 0)
        {
            const int minutesLeft = static_cast<int>((mDownloadEntry.mSize - done) / speed / 60);
            status += tr(", %1 MB/s, about %2 min left").arg(QString::number(speed / 1e6, 'f', 1)).arg(minutesLeft);
        }
        downloadStatusLabel->setText(status);
    });

    downloadButton->setEnabled(false);
    downloadProgressBar->setVisible(true);
    cancelDownloadButton->setVisible(true);
    downloadProgressBar->setValue(static_cast<int>(mDownloadOffset * 1000 / mDownloadEntry.mSize));
    downloadStatusLabel->setText(tr("Connecting…"));
}

void Launcher::AiPage::onDownloadData()
{
    if (!mDownloadChecked)
    {
        mDownloadChecked = true;
        const int status = mDownloadReply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (status == 200 && mDownloadOffset > 0)
        {
            // The server ignored the range: start over
            mDownloadFile.resize(0);
            mDownloadOffset = 0;
        }
        else if (status != 200 && status != 206)
            return;
    }
    if (mDownloadFile.write(mDownloadReply->readAll()) < 0)
    {
        mDownloadCancelled = true;
        mDownloadReply->abort();
        finishDownload(false, tr("Could not write %1: %2").arg(mDownloadFile.fileName(), mDownloadFile.errorString()));
    }
}

void Launcher::AiPage::onDownloadFinished()
{
    QNetworkReply* reply = mDownloadReply;
    mDownloadReply = nullptr;
    reply->deleteLater();
    if (mDownloadFile.isOpen())
        mDownloadFile.close();
    cancelDownloadButton->setVisible(false);

    if (mDownloadCancelled)
    {
        // A write error has already been reported and hid the progress bar
        if (downloadProgressBar->isVisible())
            finishDownload(false, tr("Download paused. Click Download to resume."));
        return;
    }
    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (reply->error() != QNetworkReply::NoError || (status != 200 && status != 206))
    {
        finishDownload(false,
            tr("Download failed: %1. Click Download to resume.")
                .arg(status >= 400 ? QStringLiteral("HTTP %1").arg(status) : reply->errorString()));
        return;
    }
    if (QFileInfo(mDownloadFile.fileName()).size() != mDownloadEntry.mSize)
    {
        finishDownload(false, tr("Download incomplete. Click Download to resume."));
        return;
    }
    verifyDownload(mDownloadFile.fileName(), mDownloadEntry);
}

void Launcher::AiPage::verifyDownload(const QString& partPath, const CatalogueEntry& entry)
{
    downloadButton->setEnabled(false);
    downloadProgressBar->setVisible(false);
    downloadStatusLabel->setText(tr("Checking the download…"));
    QPointer<AiPage> page(this);
    std::thread([page, partPath, entry] {
        QFile file(partPath);
        QCryptographicHash hash(QCryptographicHash::Sha256);
        const bool read = file.open(QIODevice::ReadOnly) && hash.addData(&file);
        const bool ok = read && QString::fromLatin1(hash.result().toHex()) == entry.mSha256.toLower();
        QMetaObject::invokeMethod(
            qApp,
            [page, partPath, entry, ok] {
                if (!page)
                    return;
                if (!ok)
                {
                    QFile::remove(partPath);
                    page->finishDownload(false, tr("The download was damaged and has been deleted. Please try again."));
                    return;
                }
                const QString finalPath = QFileInfo(partPath).dir().filePath(entry.mFile);
                if (!QFile::rename(partPath, finalPath))
                {
                    page->finishDownload(false, tr("Could not rename %1.").arg(partPath));
                    return;
                }
                page->finishDownload(true, tr("%1 is installed.").arg(entry.mName));
                page->refreshModels(page->modelComboBox->currentData().toString());
            },
            Qt::QueuedConnection);
    }).detach();
}

void Launcher::AiPage::finishDownload(bool /*ok*/, const QString& message)
{
    downloadProgressBar->setVisible(false);
    cancelDownloadButton->setVisible(false);
    downloadStatusLabel->setText(message);
    downloadButton->setEnabled(catalogueTree->currentItem() != nullptr && !mDownloadReply);
    updateCatalogue();
}

void Launcher::AiPage::cancelDownload()
{
    if (!mDownloadReply)
        return;
    mDownloadCancelled = true;
    mDownloadReply->abort();
}

// Test run

void Launcher::AiPage::startTest()
{
    if (mTestProcess != nullptr)
    {
        stopTest(tr("Test stopped."));
        return;
    }
    const QString server = Files::pathToQString(LLM::serverPath(mCfgMgr.getLocalPath()));
    if (!QFileInfo::exists(server))
    {
        testStatusLabel->setText(tr("llama-server was not found at %1.").arg(server));
        return;
    }
    if (!mDevicesKnown && deviceComboBox->currentData().toString() == QStringLiteral("auto"))
    {
        testStatusLabel->setText(tr("Still looking for GPUs. Try again in a moment."));
        return;
    }
    const QString model = selectedModel();
    if (model.isEmpty())
    {
        testStatusLabel->setText(tr("No model installed. Download one above first."));
        return;
    }

    // A free port, so the test never meets a server that is already running
    QTcpServer probe;
    if (!probe.listen(QHostAddress::LocalHost, 0))
    {
        testStatusLabel->setText(tr("No free network port for the test."));
        return;
    }
    mTestPort = probe.serverPort();
    probe.close();

    const LLM::ServerOptions options{ Files::pathFromQString(model), selectedDevice(),
        contextSizeComboBox->currentData().toInt(), gpuLayersSpinBox->value(),
        static_cast<int>(vramReserveSpinBox->value() * 1024), mTestPort,
        extraArgumentsLineEdit->text().toStdString() };
    QStringList arguments;
    for (const std::string& argument : LLM::serverArguments(options))
        arguments << QString::fromStdString(argument);
    // Logs how many layers went to the GPU, reported with the result
    arguments << QStringLiteral("--log-verbosity") << QStringLiteral("4");

    mTestLog.clear();
    mTestPromptSent = false;
    testOutput->clear();
    testOutput->setVisible(false);
    mTestProcess = new QProcess(this);
    mTestProcess->setProcessChannelMode(QProcess::MergedChannels);
    connect(mTestProcess, &QProcess::readyRead, this, [this] {
        mTestLog += QString::fromUtf8(mTestProcess->readAll());
        if (mTestLog.size() > 200000)
            mTestLog = mTestLog.right(100000);
    });
    connect(mTestProcess, &QProcess::finished, this, [this](int exitCode) {
        if (mTestProcess == nullptr)
            return;
        mTestLog += QString::fromUtf8(mTestProcess->readAll());
        const QStringList lines = mTestLog.split('\n', Qt::SkipEmptyParts);
        testOutput->setPlainText(lines.mid(std::max<qsizetype>(0, lines.size() - 15)).join('\n'));
        testOutput->setVisible(true);
        stopTest(tr("The server stopped while loading (exit code %1). Its last messages are below.").arg(exitCode));
    });
    connect(mTestProcess, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart)
            stopTest(tr("Could not start llama-server."));
    });

    testButton->setText(tr("Stop"));
    testStatusLabel->setText(tr("Loading %1 on %2…")
                                 .arg(QFileInfo(model).fileName(), QString::fromStdString(options.mDevice)));
    mTestElapsed.start();
    mTestProcess->start(server, arguments);
    mTestTimer.start();
}

void Launcher::AiPage::pollTestServer()
{
    if (mTestProcess == nullptr || mTestPromptSent)
        return;
    if (mTestElapsed.elapsed() > sTestTimeoutSeconds * 1000)
    {
        stopTest(tr("The model did not finish loading."));
        return;
    }
    QNetworkRequest request(QUrl(QStringLiteral("http://127.0.0.1:%1/health").arg(mTestPort)));
    request.setTransferTimeout(1000);
    QNetworkReply* reply = mNetwork->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        reply->deleteLater();
        if (mTestProcess == nullptr || mTestPromptSent)
            return;
        if (reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() == 200)
            sendTestPrompt();
    });
}

void Launcher::AiPage::sendTestPrompt()
{
    mTestPromptSent = true;
    const double loadSeconds = mTestElapsed.elapsed() / 1000.0;
    testStatusLabel->setText(tr("Loaded in %1 s. Asking for a reply…").arg(QString::number(loadSeconds, 'f', 1)));

    QJsonObject body;
    body["prompt"] = QStringLiteral(
        "A Dunmer trader in Balmora greets a traveller who has just arrived. In one short sentence, the trader "
        "says:");
    body["n_predict"] = sTestReplyTokens;
    body["temperature"] = 0.7;
    QNetworkRequest request(QUrl(QStringLiteral("http://127.0.0.1:%1/completion").arg(mTestPort)));
    request.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    request.setTransferTimeout(120000);
    QNetworkReply* reply = mNetwork->post(request, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply, loadSeconds] {
        reply->deleteLater();
        if (mTestProcess == nullptr)
            return;
        if (reply->error() != QNetworkReply::NoError)
        {
            stopTest(tr("The server did not answer: %1").arg(reply->errorString()));
            return;
        }
        const QJsonObject result = QJsonDocument::fromJson(reply->readAll()).object();
        const double tokensPerSecond = result.value("timings").toObject().value("predicted_per_second").toDouble();
        testOutput->setPlainText(result.value("content").toString().trimmed());
        testOutput->setVisible(true);
        QString status = tr("Works. Loaded in %1 s, replies at %2 tokens per second.")
                             .arg(QString::number(loadSeconds, 'f', 1), QString::number(tokensPerSecond, 'f', 0));
        // llama.cpp logs "offloaded 30/49 layers to GPU"
        const QRegularExpressionMatch offloaded
            = QRegularExpression(QStringLiteral("offloaded (\\d+)/(\\d+) layers to GPU")).match(mTestLog);
        if (offloaded.hasMatch())
            status += tr(" %1 of %2 layers ran on the GPU.").arg(offloaded.captured(1), offloaded.captured(2));
        stopTest(status);
    });
}

void Launcher::AiPage::stopTest(const QString& status)
{
    mTestTimer.stop();
    if (mTestProcess != nullptr)
    {
        QProcess* process = mTestProcess;
        mTestProcess = nullptr;
        process->disconnect(this);
        if (process->state() != QProcess::NotRunning)
        {
            process->terminate();
            if (!process->waitForFinished(5000))
            {
                process->kill();
                process->waitForFinished(2000);
            }
        }
        process->deleteLater();
    }
    if (!status.isEmpty())
    {
        testStatusLabel->setText(status);
        testButton->setText(tr("Test"));
    }
}
