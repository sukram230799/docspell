package docspell.analysis.nlp

import java.nio.file.Path

import cats.effect._
import cats.effect.concurrent.Ref
import cats.implicits._
import fs2.Stream

import docspell.analysis.nlp.TextClassifier._
import docspell.common._

import edu.stanford.nlp.classify.ColumnDataClassifier

final class StanfordTextClassifier[F[_]: Sync: ContextShift](
    cfg: TextClassifierConfig,
    blocker: Blocker
) extends TextClassifier[F] {

  def trainClassifier[A](
      logger: Logger[F],
      data: Stream[F, Data]
  )(handler: TextClassifier.Handler[F, A]): F[A] =
    File
      .withTempDir(cfg.workingDir, "trainclassifier")
      .use { dir =>
        for {
          rawData   <- writeDataFile(blocker, dir, data)
          _         <- logger.info(s"Learning from ${rawData.count} items.")
          trainData <- splitData(logger, rawData)
          scores    <- cfg.classifierConfigs.traverse(m => train(logger, trainData, m))
          sorted = scores.sortBy(-_.score)
          res <- handler(sorted.head.model)
        } yield res
      }

  def classify(
      logger: Logger[F],
      model: ClassifierModel,
      text: String
  ): F[Option[String]] =
    Sync[F].delay {
      val cls = ColumnDataClassifier.getClassifier(
        model.model.normalize().toAbsolutePath().toString()
      )
      val cat = cls.classOf(cls.makeDatumFromLine("\t\t" + normalisedText(text)))
      Option(cat)
    }

  // --- helpers

  def train(
      logger: Logger[F],
      in: TrainData,
      props: Map[String, String]
  ): F[TrainResult] =
    for {
      _ <- logger.debug(s"Training classifier from $props")
      res <- Sync[F].delay {
        val cdc = new ColumnDataClassifier(Properties.fromMap(amendProps(in, props)))
        cdc.trainClassifier(in.train.toString())
        val score = cdc.testClassifier(in.test.toString())
        TrainResult(score.first(), ClassifierModel(in.modelFile))
      }
      _ <- logger.debug(s"Trained with result $res")
    } yield res

  def splitData(logger: Logger[F], in: RawData): F[TrainData] = {
    val nTest = (in.count * 0.15).toLong

    val td =
      TrainData(in.file.resolveSibling("train.txt"), in.file.resolveSibling("test.txt"))

    val fileLines =
      fs2.io.file
        .readAll(in.file, blocker, 4096)
        .through(fs2.text.utf8Decode)
        .through(fs2.text.lines)

    for {
      _ <- logger.debug(
        s"Splitting raw data into test/train data. Testing with $nTest entries"
      )
      _ <-
        fileLines
          .take(nTest)
          .intersperse("\n")
          .through(fs2.text.utf8Encode)
          .through(fs2.io.file.writeAll(td.test, blocker))
          .compile
          .drain
      _ <-
        fileLines
          .drop(nTest)
          .intersperse("\n")
          .through(fs2.text.utf8Encode)
          .through(fs2.io.file.writeAll(td.train, blocker))
          .compile
          .drain
    } yield td
  }

  def writeDataFile(blocker: Blocker, dir: Path, data: Stream[F, Data]): F[RawData] = {
    val target = dir.resolve("rawdata")
    for {
      counter <- Ref.of[F, Long](0L)
      _ <-
        data
          .filter(_.text.nonEmpty)
          .map(d => s"${d.cls}\t${fixRef(d.ref)}\t${normalisedText(d.text)}")
          .evalTap(_ => counter.update(_ + 1))
          .intersperse("\r\n")
          .through(fs2.text.utf8Encode)
          .through(fs2.io.file.writeAll(target, blocker))
          .compile
          .drain
      lines <- counter.get
    } yield RawData(lines, target)

  }

  def normalisedText(text: String): String =
    text.replaceAll("[\n\r\t]+", " ")

  def fixRef(str: String): String =
    str.replace('\t', '_')

  def amendProps(
      trainData: TrainData,
      props: Map[String, String]
  ): Map[String, String] =
    prepend("2.", props) ++ Map(
      "trainFile"   -> trainData.train.normalize().toAbsolutePath().toString(),
      "testFile"    -> trainData.test.normalize().toAbsolutePath().toString(),
      "serializeTo" -> trainData.modelFile.normalize().toAbsolutePath().toString()
    ).toList

  case class RawData(count: Long, file: Path)
  case class TrainData(train: Path, test: Path) {
    val modelFile = train.resolveSibling("model.ser.gz")
  }

  case class TrainResult(score: Double, model: ClassifierModel)

  def prepend(pre: String, data: Map[String, String]): Map[String, String] =
    data.toList
      .map({
        case (k, v) =>
          if (k.startsWith(pre)) (k, v)
          else (pre + k, v)
      })
      .toMap
}
